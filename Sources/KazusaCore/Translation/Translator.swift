// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation

public struct TranslationRequest: Sendable, Equatable {
    public var text: String
    /// 上文（原文, 译文）对，按时间顺序。
    public var context: [(source: String, translation: String)]
    public var glossary: [String: String]

    public init(text: String, context: [(source: String, translation: String)] = [], glossary: [String: String] = [:]) {
        self.text = text
        self.context = context
        self.glossary = glossary
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.glossary == rhs.glossary
            && lhs.context.map(\.source) == rhs.context.map(\.source)
            && lhs.context.map(\.translation) == rhs.context.map(\.translation)
    }
}

public enum TranslationError: LocalizedError, Equatable {
    case invalidBaseURL(String)
    case missingAPIKey
    case http(status: Int, body: String)
    case badResponse(String)
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let s): "接口地址无效：\(s)"
        case .missingAPIKey: "没有填写 API Key"
        case .http(let status, let body): "HTTP \(status)：\(body.prefix(300))"
        case .badResponse(let s): "无法解析返回内容：\(s.prefix(300))"
        case .refused(let s): "模型拒绝了这次请求：\(s)"
        }
    }
}

/// 可替换的 HTTP 层，方便测试。
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// 按行读取响应体（用于 SSE 流式输出）。
    func lines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse)
}

extension HTTPTransport {
    /// 默认实现：整体读完再按行切开。
    public func lines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        let (data, response) = try await send(request)
        let all = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        return (AsyncThrowingStream { continuation in
            for line in all { continuation.yield(line) }
            continuation.finish()
        }, response)
    }
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranslationError.badResponse("非 HTTP 响应")
        }
        return (data, http)
    }

    public func lines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranslationError.badResponse("非 HTTP 响应")
        }
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (stream, http)
    }
}

/// 把配置 + 提示词变成一次 HTTP 请求，并解析结果。两种协议共用这一个类型。
public struct LLMTranslator: Sendable {
    public var provider: LLMProviderConfig
    public var prompt: TranslationPromptConfig
    public var apiKey: String?
    public var transport: any HTTPTransport

    public init(provider: LLMProviderConfig, prompt: TranslationPromptConfig, apiKey: String?, transport: any HTTPTransport = URLSessionTransport()) {
        self.provider = provider
        self.prompt = prompt
        self.apiKey = apiKey
        self.transport = transport
    }

    public func translate(_ request: TranslationRequest) async throws -> String {
        let urlRequest = try makeURLRequest(request)
        let (data, response) = try await transport.send(urlRequest)
        guard (200..<300).contains(response.statusCode) else {
            throw TranslationError.http(status: response.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return try parse(data).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 流式翻译：每收到一段就用“目前为止的可见译文”回调一次，最后返回完整译文。
    public func translateStreaming(
        _ request: TranslationRequest,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let urlRequest = try makeURLRequest(request, stream: true)
        let (lines, response) = try await transport.lines(urlRequest)
        var accumulated = ""
        var raw: [String] = []
        var sawEvent = false

        for try await line in lines {
            guard (200..<300).contains(response.statusCode) else { raw.append(line); continue }
            guard line.hasPrefix("data:") else { raw.append(line); continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            sawEvent = true
            if let delta = try streamDelta(json), !delta.isEmpty {
                accumulated += delta
                onPartial(Self.visibleText(accumulated))
            }
        }

        guard (200..<300).contains(response.statusCode) else {
            throw TranslationError.http(status: response.statusCode, body: raw.joined(separator: "\n"))
        }
        // 有的中转服务忽略 stream 参数，直接返回普通 JSON。
        if !sawEvent {
            return try parse(Data(raw.joined(separator: "\n").utf8)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let result = Self.stripReasoning(accumulated).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw TranslationError.badResponse("流式响应里没有文本") }
        return result
    }

    /// 从一条 SSE 事件里取出新增的文本。
    func streamDelta(_ json: [String: Any]) throws -> String? {
        switch provider.style {
        case .openAICompatible:
            if let error = json["error"] as? [String: Any] {
                throw TranslationError.badResponse(error["message"] as? String ?? "\(error)")
            }
            let choices = json["choices"] as? [[String: Any]]
            let delta = choices?.first?["delta"] as? [String: Any]
            return delta?["content"] as? String

        case .anthropic:
            switch json["type"] as? String {
            case "content_block_delta":
                let delta = json["delta"] as? [String: Any]
                return delta?["type"] as? String == "text_delta" ? delta?["text"] as? String : nil
            case "message_delta":
                let delta = json["delta"] as? [String: Any]
                if delta?["stop_reason"] as? String == "refusal" {
                    let details = delta?["stop_details"] as? [String: Any]
                    throw TranslationError.refused(details?["explanation"] as? String ?? "未说明原因")
                }
                return nil
            case "error":
                let error = json["error"] as? [String: Any]
                throw TranslationError.badResponse(error?["message"] as? String ?? "\(json)")
            default:
                return nil
            }
        }
    }

    // MARK: - Prompt

    func systemPrompt() -> String {
        prompt.systemPrompt.replacingOccurrences(of: "{target}", with: prompt.targetLanguage)
    }

    func userMessage(_ request: TranslationRequest) -> String {
        var parts: [String] = []
        if !request.glossary.isEmpty {
            let lines = request.glossary.sorted { $0.key < $1.key }.map { "\($0.key) → \($0.value)" }
            parts.append("【术语表】\n" + lines.joined(separator: "\n"))
        }
        let context = request.context.suffix(prompt.contextLines)
        if !context.isEmpty {
            let lines = context.map { "原文：\($0.source)\n译文：\($0.translation)" }
            parts.append("【上文（仅供参考，不要翻译）】\n" + lines.joined(separator: "\n"))
        }
        parts.append("【需要翻译的文本】\n" + request.text)
        return parts.joined(separator: "\n\n")
    }

    // MARK: - HTTP

    func endpoint() throws -> URL {
        var base = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        let path: String
        switch provider.style {
        case .openAICompatible:
            path = base.hasSuffix("/chat/completions") ? "" : "/chat/completions"
        case .anthropic:
            if base.hasSuffix("/v1/messages") { path = "" }
            else if base.hasSuffix("/v1") { path = "/messages" }
            else { path = "/v1/messages" }
        }
        guard let url = URL(string: base + path), let scheme = url.scheme, ["http", "https"].contains(scheme) else {
            throw TranslationError.invalidBaseURL(provider.baseURL)
        }
        return url
    }

    func makeURLRequest(_ request: TranslationRequest, stream: Bool = false) throws -> URLRequest {
        var urlRequest = URLRequest(url: try endpoint(), timeoutInterval: provider.timeoutSeconds)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let body: [String: Any]
        switch provider.style {
        case .openAICompatible:
            // 本地模型（Ollama 等）通常不需要 key。
            if !key.isEmpty { urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            var b: [String: Any] = [
                "model": provider.model,
                "messages": [
                    ["role": "system", "content": systemPrompt()],
                    ["role": "user", "content": userMessage(request)],
                ],
                "stream": stream,
            ]
            if let t = provider.temperature { b["temperature"] = t }
            body = b

        case .anthropic:
            guard !key.isEmpty else { throw TranslationError.missingAPIKey }
            urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
            urlRequest.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
            var b: [String: Any] = [
                "model": provider.model,
                "max_tokens": 4096,
                "system": systemPrompt(),
                "messages": [["role": "user", "content": userMessage(request)]],
                // 逐句翻译不需要深度思考，用低 effort 换取速度和成本。
                "output_config": ["effort": "low"],
            ]
            if stream { b["stream"] = true }
            body = b
        }
        for (k, v) in provider.extraHeaders { urlRequest.setValue(v, forHTTPHeaderField: k) }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return urlRequest
    }

    func parse(_ data: Data) throws -> String {
        let raw = String(decoding: data, as: UTF8.self)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranslationError.badResponse(raw)
        }
        switch provider.style {
        case .openAICompatible:
            guard let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                throw TranslationError.badResponse(raw)
            }
            return Self.stripReasoning(content)

        case .anthropic:
            if json["stop_reason"] as? String == "refusal" {
                let details = json["stop_details"] as? [String: Any]
                throw TranslationError.refused(details?["explanation"] as? String ?? "未说明原因")
            }
            guard let content = json["content"] as? [[String: Any]] else {
                throw TranslationError.badResponse(raw)
            }
            let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else { throw TranslationError.badResponse(raw) }
            return text
        }
    }

    /// 一些推理模型（如本地 Qwen / DeepSeek-R1）会把 <think>…</think> 混进正文，去掉它。
    static func stripReasoning(_ s: String) -> String {
        guard let end = s.range(of: "</think>") else { return s }
        return String(s[end.upperBound...])
    }

    /// 流式输出过程中可以展示的部分：还在 <think> 里时什么都不显示。
    static func visibleText(_ s: String) -> String {
        if s.range(of: "</think>") == nil, s.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<think>") { return "" }
        return stripReasoning(s).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
