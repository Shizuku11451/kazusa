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

final class PartialRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String] = []
    func add(_ s: String) { lock.withLock { _values.append(s) } }
    var values: [String] { lock.withLock { _values } }
}

@Suite struct StreamingTests {
    let openAI = LLMProviderConfig(name: "t", style: .openAICompatible, baseURL: "https://api.example.com/v1", model: "m")
    let anthropic = LLMProviderConfig(name: "c", style: .anthropic, baseURL: "https://api.anthropic.com", model: "claude-opus-5-5")

    @Test func openAIStream() async throws {
        let body = """
        data: {"choices":[{"delta":{"role":"assistant"}}]}

        data: {"choices":[{"delta":{"content":"你"}}]}

        data: {"choices":[{"delta":{"content":"好。"}}]}

        data: [DONE]
        """
        let stub = StubTransport(body: body)
        let t = LLMTranslator(provider: openAI, prompt: .init(), apiKey: "k", transport: stub)
        let rec = PartialRecorder()
        let out = try await t.translateStreaming(TranslationRequest(text: "こんにちは。")) { rec.add($0) }
        #expect(out == "你好。")
        #expect(rec.values == ["你", "你好。"])
        let sent = try JSONSerialization.jsonObject(with: try #require(stub.requests.first?.httpBody)) as? [String: Any]
        #expect(sent?["stream"] as? Bool == true)
    }

    @Test func anthropicStream() async throws {
        let body = """
        event: message_start
        data: {"type":"message_start","message":{"content":[]}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"早上"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"好"}}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

        event: message_stop
        data: {"type":"message_stop"}
        """
        let t = LLMTranslator(provider: anthropic, prompt: .init(), apiKey: "k", transport: StubTransport(body: body))
        let rec = PartialRecorder()
        let out = try await t.translateStreaming(TranslationRequest(text: "おはよう")) { rec.add($0) }
        #expect(out == "早上好")
        #expect(rec.values == ["早上", "早上好"])
    }

    @Test func anthropicStreamRefusal() async throws {
        let body = #"data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}"#
        let t = LLMTranslator(provider: anthropic, prompt: .init(), apiKey: "k", transport: StubTransport(body: body))
        await #expect(throws: TranslationError.self) {
            _ = try await t.translateStreaming(TranslationRequest(text: "x")) { _ in }
        }
    }

    @Test func hidesThinkingWhileStreaming() async throws {
        let body = """
        data: {"choices":[{"delta":{"content":"<think>嗯"}}]}
        data: {"choices":[{"delta":{"content":"</think>译文"}}]}
        data: [DONE]
        """
        let t = LLMTranslator(provider: openAI, prompt: .init(), apiKey: nil, transport: StubTransport(body: body))
        let rec = PartialRecorder()
        let out = try await t.translateStreaming(TranslationRequest(text: "x")) { rec.add($0) }
        #expect(out == "译文")
        #expect(rec.values == ["", "译文"])
    }

    @Test func fallsBackToPlainJSON() async throws {
        let stub = StubTransport(body: #"{"choices":[{"message":{"content":"普通"}}]}"#)
        let t = LLMTranslator(provider: openAI, prompt: .init(), apiKey: nil, transport: stub)
        let out = try await t.translateStreaming(TranslationRequest(text: "x")) { _ in }
        #expect(out == "普通")
    }

    @Test func httpErrorWhileStreaming() async throws {
        let stub = StubTransport(status: 401, body: #"{"error":"bad key"}"#)
        let t = LLMTranslator(provider: openAI, prompt: .init(), apiKey: nil, transport: stub)
        await #expect(throws: TranslationError.self) {
            _ = try await t.translateStreaming(TranslationRequest(text: "x")) { _ in }
        }
    }
}

@Suite struct TranslationStoreTests {
    let provider = LLMProviderConfig(name: "t", style: .openAICompatible, baseURL: "http://localhost:1/v1", model: "m")

    func tempStore() -> TranslationStore {
        TranslationStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("kazusa-test-\(UUID().uuidString)/t.jsonl"))
    }

    func session(_ store: TranslationStore, _ stub: StubTransport, language: String = "简体中文") -> TranslationSession {
        TranslationSession(translator: LLMTranslator(provider: provider, prompt: .init(targetLanguage: language), apiKey: nil, transport: stub),
                           store: store)
    }

    @Test func translationsSurviveNewSession() async throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let stub = StubTransport(body: #"{"choices":[{"message":{"content":"译"}}]}"#)

        let first = session(store, stub)
        _ = try await first.submit("A")
        _ = try await first.submit("B")
        #expect(stub.requests.count == 2)

        let second = session(store, stub)
        #expect(await second.lines.map(\.source) == ["A", "B"])
        _ = try await second.submit("A")
        #expect(stub.requests.count == 2) // 记录里有，不再请求

        // 换了目标语言就不用这些记录。
        let english = session(store, stub, language: "English")
        #expect(await english.lines.isEmpty)
        _ = try await english.submit("A")
        #expect(stub.requests.count == 3)
        #expect(store.load(language: "简体中文").count == 2)
    }

    @Test func clearAndCorruptLines() async throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.append(.init(source: "A", translation: "甲", language: "zh"))
        let handle = try FileHandle(forWritingTo: store.fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"s":"半"#.utf8)) // 写到一半
        try handle.close()
        #expect(store.load(language: "zh") == [.init(source: "A", translation: "甲", language: "zh")])

        let stub = StubTransport(body: #"{"choices":[{"message":{"content":"译"}}]}"#)
        let s = session(store, stub, language: "zh")
        try await s.clear()
        #expect(await s.lines.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }
}
