// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation

/// 一次游玩过程中的翻译会话：去重、缓存、维护上文。
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

    public init(translator: LLMTranslator, glossary: [String: String] = [:]) {
        self.translator = translator
        self.glossary = glossary
    }

    public func update(translator: LLMTranslator, glossary: [String: String]) {
        self.translator = translator
        self.glossary = glossary
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
