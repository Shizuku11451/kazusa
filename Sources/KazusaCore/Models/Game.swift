// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation

/// 游戏运行时使用的区域（决定 Wine 里的 ANSI 代码页，也就是“转区”）。
public enum GameLocale: String, Codable, CaseIterable, Sendable {
    /// 简体中文（GBK / CP936）——大多数汉化版需要这个。
    case simplifiedChinese
    /// 繁体中文（Big5 / CP950）
    case traditionalChinese
    /// 日语（Shift-JIS / CP932）——日文原版需要这个。
    case japanese

    public var posixLocale: String {
        switch self {
        case .simplifiedChinese: "zh_CN.UTF-8"
        case .traditionalChinese: "zh_TW.UTF-8"
        case .japanese: "ja_JP.UTF-8"
        }
    }

    public var displayName: String {
        switch self {
        case .simplifiedChinese: "简体中文 (GBK)"
        case .traditionalChinese: "繁体中文 (Big5)"
        case .japanese: "日语 (Shift-JIS)"
        }
    }

    /// 默认共用前缀名。同一区域的游戏共用一个前缀，节省空间；需要隔离时可以给单个游戏改名。
    public var defaultPrefixName: String {
        switch self {
        case .simplifiedChinese: "default-zhs"
        case .traditionalChinese: "default-zht"
        case .japanese: "default-ja"
        }
    }

    /// OCR 识别时的源语言（Vision 语言代码）。
    public var ocrLanguages: [String] {
        switch self {
        case .simplifiedChinese: ["zh-Hans", "ja-JP"]
        case .traditionalChinese: ["zh-Hant", "ja-JP"]
        case .japanese: ["ja-JP"]
        }
    }
}

public struct GameTranslationSettings: Codable, Hashable, Sendable {
    /// 是否在启动时打开翻译悬浮窗。日文原版默认开启，汉化版默认关闭。
    public var enabled: Bool
    /// 人名、专有名词对照表，例如 ["冬馬かずさ": "冬马和纱"]。会注入翻译提示词。
    public var glossary: [String: String]

    public init(enabled: Bool = false, glossary: [String: String] = [:]) {
        self.enabled = enabled
        self.glossary = glossary
    }
}

public struct Game: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    /// 游戏根目录。
    public var directory: URL
    /// 相对 directory 的主程序路径，例如 "WA2.exe" 或 "bin/game.exe"。
    public var executable: String
    public var engine: EngineKind
    public var locale: GameLocale
    public var prefixName: String
    public var arguments: [String]
    /// 额外环境变量，会覆盖默认值（例如 WINEDLLOVERRIDES）。
    public var environment: [String: String]
    public var translation: GameTranslationSettings
    public var addedAt: Date
    public var lastPlayedAt: Date?
    public var totalPlaySeconds: TimeInterval
    /// 对应的 VNDB 条目（如 "v3144"），获取封面时记下。旧的游戏库里没有这个字段。
    public var vndbID: String?
    /// 从 VNDB 拉来的简介、品牌等资料。没有关联条目或还没拉取时为空。
    public var metadata: GameMetadata?

    public init(
        id: UUID = UUID(),
        title: String,
        directory: URL,
        executable: String,
        engine: EngineKind,
        locale: GameLocale,
        prefixName: String? = nil,
        arguments: [String] = [],
        environment: [String: String] = [:],
        translation: GameTranslationSettings? = nil,
        addedAt: Date = Date(),
        lastPlayedAt: Date? = nil,
        totalPlaySeconds: TimeInterval = 0,
        vndbID: String? = nil,
        metadata: GameMetadata? = nil
    ) {
        self.id = id
        self.title = title
        self.directory = directory
        self.executable = executable
        self.engine = engine
        self.locale = locale
        self.prefixName = prefixName ?? locale.defaultPrefixName
        self.arguments = arguments
        self.environment = environment
        self.translation = translation ?? GameTranslationSettings(enabled: locale == .japanese)
        self.addedAt = addedAt
        self.lastPlayedAt = lastPlayedAt
        self.totalPlaySeconds = totalPlaySeconds
        self.vndbID = vndbID
        self.metadata = metadata
    }

    public var executableURL: URL {
        directory.appendingPathComponent(executable)
    }
}
