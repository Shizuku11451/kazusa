// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation

public struct AppSettings: Codable, Hashable, Sendable {
    /// 用户手动指定的 wine 可执行文件路径；为空时自动发现。
    public var customWineBinary: String
    /// 选中的运行时（wine 路径）；为空时用发现到的第一个。
    public var selectedRuntimePath: String
    /// Windows 中日文字体映射到的 macOS 字体。
    public var cjkFont: String

    public var providers: [LLMProviderConfig]
    public var activeProviderID: UUID?
    public var prompt: TranslationPromptConfig

    public init(
        customWineBinary: String = "",
        selectedRuntimePath: String = "",
        cjkFont: String = FontSubstitutes.defaultTargetFont,
        providers: [LLMProviderConfig] = [LLMProviderConfig.presets[0]],
        activeProviderID: UUID? = nil,
        prompt: TranslationPromptConfig = TranslationPromptConfig()
    ) {
        self.customWineBinary = customWineBinary
        self.selectedRuntimePath = selectedRuntimePath
        self.cjkFont = cjkFont
        self.providers = providers
        self.activeProviderID = activeProviderID ?? providers.first?.id
        self.prompt = prompt
    }

    public var activeProvider: LLMProviderConfig? {
        providers.first { $0.id == activeProviderID } ?? providers.first
    }

    public static func load(from url: URL) -> AppSettings {
        (try? JSONFile.read(AppSettings.self, from: url)) ?? AppSettings()
    }

    public func save(to url: URL) throws {
        try JSONFile.write(self, to: url)
    }
}
