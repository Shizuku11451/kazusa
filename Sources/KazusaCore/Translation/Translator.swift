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

    func makeURLRequest(_ request: TranslationRequest) throws -> URLRequest {
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
                "stream": false,
            ]
            if let t = provider.temperature { b["temperature"] = t }
            body = b

        case .anthropic:
            guard !key.isEmpty else { throw TranslationError.missingAPIKey }
            urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
            urlRequest.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
            body = [
                "model": provider.model,
                "max_tokens": 4096,
                "system": systemPrompt(),
                "messages": [["role": "user", "content": userMessage(request)]],
                // 逐句翻译不需要深度思考，用低 effort 换取速度和成本。
                "output_config": ["effort": "low"],
            ]
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
}
