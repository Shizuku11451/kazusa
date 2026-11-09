// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation

/// 一个游戏的翻译会话：去重、缓存、维护上文。传入 store 时翻过的句子会存下来，下次直接用。
public actor TranslationSession {
    public struct Line: Sendable, Identifiable, Equatable {
        public let id = UUID()
        public var source: String
        public var translation: String
    }

    private var translator: LLMTranslator
    private var glossary: [String: String]
    private var history: [Line] = []
    private var cache: [String: String] = [:]
    private let historyLimit = 200
    private let store: TranslationStore?
    /// 最近一次写记录失败的原因（磁盘满、没权限等）；不影响翻译本身。
    public private(set) var storeError: String?

    public init(translator: LLMTranslator, glossary: [String: String] = [:], store: TranslationStore? = nil) {
        self.translator = translator
        self.glossary = glossary
        self.store = store
        (history, cache) = Self.restore(from: store, language: translator.prompt.targetLanguage, historyLimit: historyLimit)
    }

    public func update(translator: LLMTranslator, glossary: [String: String]) {
        let languageChanged = translator.prompt.targetLanguage != self.translator.prompt.targetLanguage
        self.translator = translator
        self.glossary = glossary
        if languageChanged {
            (history, cache) = Self.restore(from: store, language: translator.prompt.targetLanguage, historyLimit: historyLimit)
        }
    }

    /// 清空记录（内存和文件）。之后同样的句子会重新调用 LLM 翻译。
    public func clear() throws {
        history = []
        cache = [:]
        try store?.clear()
    }

    private static func restore(from store: TranslationStore?, language: String, historyLimit: Int) -> ([Line], [String: String]) {
        guard let records = store?.load(language: language) else { return ([], [:]) }
        var cache: [String: String] = [:]
        for r in records { cache[r.source] = r.translation }
        let history = records.suffix(historyLimit).map { Line(source: $0.source, translation: $0.translation) }
        return (history, cache)
    }

    public var lines: [Line] { history }

    /// 翻译一句。与上一句相同（OCR 反复识别到同一画面）时直接返回 nil。
    /// - Parameter onPartial: 传入时使用流式输出，回调参数是（原文, 目前为止的译文）。
    public func submit(_ rawText: String, onPartial: (@Sendable (String, String) -> Void)? = nil) async throws -> Line? {
        let text = Self.normalize(rawText)
        guard !text.isEmpty else { return nil }
        if history.last?.source == text { return nil }

        let translation: String
        if let cached = cache[text] {
            translation = cached
        } else {
            let context = history.map { (source: $0.source, translation: $0.translation) }
            let request = TranslationRequest(text: text, context: context, glossary: glossary)
            if let onPartial {
                translation = try await translator.translateStreaming(request) { onPartial(text, $0) }
            } else {
                translation = try await translator.translate(request)
            }
            cache[text] = translation
            do {
                try store?.append(.init(source: text, translation: translation, language: translator.prompt.targetLanguage))
                storeError = nil
            } catch {
                storeError = error.localizedDescription
            }
        }

        let line = Line(source: text, translation: translation)
        history.append(line)
        if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
        return line
    }

    /// OCR 结果常带奇怪的换行和空格：合并成一段。日文/中文之间不需要空格。
    public static func normalize(_ s: String) -> String {
        let lines = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.joined()
    }
}
