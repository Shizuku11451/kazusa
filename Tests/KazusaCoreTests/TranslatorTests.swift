// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation
import Testing
@testable import KazusaCore

/// 记录请求并返回固定响应的假 HTTP 层。
final class StubTransport: HTTPTransport, @unchecked Sendable {
    let status: Int
    let body: String
    private let lock = NSLock()
    private var _requests: [URLRequest] = []

    init(status: Int = 200, body: String) {
        self.status = status
        self.body = body
    }

    var requests: [URLRequest] {
        lock.withLock { _requests }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

func jsonBody(_ request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Suite struct TranslatorTests {
    let openAI = LLMProviderConfig(name: "t", style: .openAICompatible, baseURL: "https://api.example.com/v1/", model: "m", temperature: 0.2)
    let anthropic = LLMProviderConfig(name: "c", style: .anthropic, baseURL: "https://api.anthropic.com", model: "claude-opus-5-5")

    @Test func openAIRequestAndResponse() async throws {
        let stub = StubTransport(body: #"{"choices":[{"message":{"role":"assistant","content":"  你好。\n"}}]}"#)
        let t = LLMTranslator(provider: openAI, prompt: .init(), apiKey: "sk-1", transport: stub)
        let out = try await t.translate(TranslationRequest(text: "こんにちは。", glossary: ["かずさ": "和纱"]))
        #expect(out == "你好。")

        let req = try #require(stub.requests.first)
        #expect(req.url?.absoluteString == "https://api.example.com/v1/chat/completions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-1")
        let body = try jsonBody(req)
        #expect(body["model"] as? String == "m")
        #expect(body["temperature"] as? Double == 0.2)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages[0]["role"] == "system")
        #expect(messages[0]["content"]?.contains("简体中文") == true)
        #expect(messages[1]["content"]?.contains("かずさ → 和纱") == true)
        #expect(messages[1]["content"]?.hasSuffix("こんにちは。") == true)
    }

    @Test func openAIWithoutKeySendsNoAuthHeader() throws {
        let t = LLMTranslator(provider: openAI, prompt: .init(), apiKey: nil, transport: StubTransport(body: "{}"))
        let req = try t.makeURLRequest(TranslationRequest(text: "a"))
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func anthropicRequestAndResponse() async throws {
        let stub = StubTransport(body: #"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"冬马和纱"}],"stop_reason":"end_turn"}"#)
        let t = LLMTranslator(provider: anthropic, prompt: .init(), apiKey: "k", transport: stub)
        let out = try await t.translate(TranslationRequest(text: "冬馬かずさ"))
        #expect(out == "冬马和纱")

        let req = try #require(stub.requests.first)
        #expect(req.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(req.value(forHTTPHeaderField: "x-api-key") == "k")
        #expect(req.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        let body = try jsonBody(req)
        #expect(body["temperature"] == nil)
        #expect(body["system"] is String)
        #expect((body["output_config"] as? [String: String])?["effort"] == "low")
    }

    @Test func anthropicRequiresKey() {
        let t = LLMTranslator(provider: anthropic, prompt: .init(), apiKey: "", transport: StubTransport(body: "{}"))
        #expect(throws: TranslationError.missingAPIKey) { try t.makeURLRequest(TranslationRequest(text: "a")) }
    }

    @Test func anthropicRefusalSurfaces() async {
        let stub = StubTransport(body: #"{"content":[],"stop_reason":"refusal","stop_details":{"type":"refusal","explanation":"x"}}"#)
        let t = LLMTranslator(provider: anthropic, prompt: .init(), apiKey: "k", transport: stub)
        await #expect(throws: TranslationError.refused("x")) { try await t.translate(TranslationRequest(text: "a")) }
    }

    @Test func httpErrorSurfaces() async {
        let stub = StubTransport(status: 401, body: "bad key")
        let t = LLMTranslator(provider: openAI, prompt: .init(), apiKey: "k", transport: stub)
        await #expect(throws: TranslationError.http(status: 401, body: "bad key")) { try await t.translate(TranslationRequest(text: "a")) }
    }

    @Test func stripsThinkTags() {
        #expect(LLMTranslator.stripReasoning("<think>hmm</think>\n译文") == "\n译文")
        #expect(LLMTranslator.stripReasoning("译文") == "译文")
    }

    @Test(arguments: [
        ("https://api.anthropic.com", "https://api.anthropic.com/v1/messages"),
        ("https://proxy.example.com/v1", "https://proxy.example.com/v1/messages"),
        ("https://proxy.example.com/v1/messages", "https://proxy.example.com/v1/messages"),
    ])
    func anthropicEndpointVariants(base: String, expected: String) throws {
        var p = anthropic
        p.baseURL = base
        let t = LLMTranslator(provider: p, prompt: .init(), apiKey: "k", transport: StubTransport(body: "{}"))
        #expect(try t.endpoint().absoluteString == expected)
    }

    @Test func rejectsInvalidBaseURL() {
        var p = openAI
        p.baseURL = "not a url"
        let t = LLMTranslator(provider: p, prompt: .init(), apiKey: nil, transport: StubTransport(body: "{}"))
        #expect(throws: TranslationError.self) { try t.endpoint() }
    }
}

@Suite struct TranslationSessionTests {
    @Test func dedupesAndCarriesContext() async throws {
        let stub = StubTransport(body: #"{"choices":[{"message":{"content":"译"}}]}"#)
        let provider = LLMProviderConfig(name: "t", style: .openAICompatible, baseURL: "http://localhost:1/v1", model: "m")
        let session = TranslationSession(translator: LLMTranslator(provider: provider, prompt: .init(), apiKey: nil, transport: stub))

        #expect(try await session.submit("一行目\n  です") != nil)
        #expect(try await session.submit("一行目です") == nil) // 与上一句相同 → 跳过
        #expect(try await session.submit("二行目") != nil)
        #expect(try await session.submit("   ") == nil)
        #expect(stub.requests.count == 2)

        let second = try jsonBody(stub.requests[1])
        let user = try #require((second["messages"] as? [[String: String]])?.last?["content"])
        #expect(user.contains("原文：一行目です"))
        #expect(await session.lines.map(\.source) == ["一行目です", "二行目"])
    }

    @Test func cacheAvoidsRepeatRequests() async throws {
        let stub = StubTransport(body: #"{"choices":[{"message":{"content":"译"}}]}"#)
        let provider = LLMProviderConfig(name: "t", style: .openAICompatible, baseURL: "http://localhost:1/v1", model: "m")
        let session = TranslationSession(translator: LLMTranslator(provider: provider, prompt: .init(), apiKey: nil, transport: stub))
        _ = try await session.submit("A")
        _ = try await session.submit("B")
        _ = try await session.submit("A")
        #expect(stub.requests.count == 2)
    }
}
