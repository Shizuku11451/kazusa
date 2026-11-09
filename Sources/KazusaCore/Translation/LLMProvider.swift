// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation

/// 支持的接口协议。“OpenAI 兼容”覆盖 DeepSeek、通义千问、Kimi、OpenRouter、Ollama、LM Studio 等。
public enum LLMAPIStyle: String, Codable, CaseIterable, Sendable {
    case openAICompatible
    case anthropic

    public var displayName: String {
        switch self {
        case .openAICompatible: "OpenAI 兼容 (/chat/completions)"
        case .anthropic: "Anthropic (/v1/messages)"
        }
    }
}

/// 用户自定义的一个 LLM 服务。API Key 不存在这里，而是存在钥匙串里（按 id 索引）。
public struct LLMProviderConfig: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var style: LLMAPIStyle
    /// 例如 https://api.deepseek.com/v1 、http://localhost:11434/v1 、https://api.anthropic.com
    public var baseURL: String
    public var model: String
    /// 只对 OpenAI 兼容接口生效（Anthropic 新版 API 不再接受采样参数）。
    public var temperature: Double?
    public var extraHeaders: [String: String]
    public var timeoutSeconds: Double

    public init(
        id: UUID = UUID(),
        name: String,
        style: LLMAPIStyle,
        baseURL: String,
        model: String,
        temperature: Double? = nil,
        extraHeaders: [String: String] = [:],
        timeoutSeconds: Double = 60
    ) {
        self.id = id
        self.name = name
        self.style = style
        self.baseURL = baseURL
        self.model = model
        self.temperature = temperature
        self.extraHeaders = extraHeaders
        self.timeoutSeconds = timeoutSeconds
    }

    public static let presets: [LLMProviderConfig] = [
        LLMProviderConfig(name: "DeepSeek", style: .openAICompatible, baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat", temperature: 0.3),
        LLMProviderConfig(name: "Claude", style: .anthropic, baseURL: "https://api.anthropic.com", model: "claude-opus-5-5"),
        LLMProviderConfig(name: "Ollama（本地）", style: .openAICompatible, baseURL: "http://localhost:11434/v1", model: "qwen3:14b", temperature: 0.3),
        LLMProviderConfig(name: "LM Studio（本地）", style: .openAICompatible, baseURL: "http://localhost:1234/v1", model: "local-model", temperature: 0.3),
    ]
}

/// 翻译提示词配置。
public struct TranslationPromptConfig: Codable, Hashable, Sendable {
    public var targetLanguage: String
    public var systemPrompt: String
    /// 附带多少句上文，帮助模型保持人称和语气一致。
    public var contextLines: Int

    public init(targetLanguage: String = "简体中文", systemPrompt: String = TranslationPromptConfig.defaultSystemPrompt, contextLines: Int = 6) {
        self.targetLanguage = targetLanguage
        self.systemPrompt = systemPrompt
        self.contextLines = contextLines
    }

    public static let defaultSystemPrompt = """
    你是一名专业的视觉小说（galgame）译者。把用户给出的游戏文本翻译成{target}。
    要求：
    - 只输出译文，不要解释、不要加引号或前缀。
    - 保留说话人的语气、口癖和称呼习惯；拟声词与语气词要自然。
    - 文本可能来自 OCR，含有少量识别错误或多余换行，请按语义修正后翻译。
    - 人名、专有名词严格按照术语表翻译。
    """
}
