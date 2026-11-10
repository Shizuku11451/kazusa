// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation

/// 从 VNDB 拉来的游戏资料（简介、品牌、发售日等），只用来展示。
public struct GameMetadata: Codable, Hashable, Sendable {
    public var vndbID: String
    /// 原语言的标题，例如“素晴らしき日々～不連続存在～”。
    public var originalTitle: String?
    /// VNDB 上登记的中文标题（优先简体）。
    public var chineseTitle: String?
    /// 品牌（开发商），用原文名，例如“ケロQ”。
    public var developers: [String]
    /// VNDB 的日期格式：“2010-03-26”“2010-03”“2010”或“TBA”。
    public var released: String?
    /// VNDB 用户统计的平均游玩时长。
    public var lengthMinutes: Int?
    /// VNDB 评分，10–100。
    public var rating: Double?
    /// 简介，已去掉 BBCode 和剧透段落。VNDB 上的简介大多是英文。
    public var synopsis: String?
    /// 用 LLM 翻译过的简介。只对应当前的 `synopsis`，原文变了就作废。
    public var synopsisTranslation: String?
    /// 不含剧透和成人内容的标签，按相关度排好。nil = 旧版本存的资料，还没拉过。
    public var tags: [String]?
    /// 不含成人和血腥内容的截图。nil 同上。
    public var screenshots: [Screenshot]?
    /// 主角和主要角色，不含剧透角色。nil 同上。
    public var characters: [Character]?
    public var fetchedAt: Date

    public struct Screenshot: Codable, Hashable, Sendable, Identifiable {
        public var url: URL
        public var thumbnail: URL
        public var id: URL { url }
        public init(url: URL, thumbnail: URL) {
            self.url = url
            self.thumbnail = thumbnail
        }
    }

    public struct Character: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
        /// 原文名，例如“冬馬かずさ”。
        public var original: String?
        /// 只有安全的图才记下。
        public var imageURL: URL?
        public var isProtagonist: Bool
        public init(id: String, name: String, original: String? = nil, imageURL: URL? = nil, isProtagonist: Bool = false) {
            self.id = id
            self.name = name
            self.original = original
            self.imageURL = imageURL
            self.isProtagonist = isProtagonist
        }
    }

    public init(vndbID: String, originalTitle: String? = nil, chineseTitle: String? = nil, developers: [String] = [],
                released: String? = nil, lengthMinutes: Int? = nil, rating: Double? = nil, synopsis: String? = nil,
                synopsisTranslation: String? = nil, tags: [String]? = nil, screenshots: [Screenshot]? = nil,
                characters: [Character]? = nil, fetchedAt: Date = Date()) {
        self.vndbID = vndbID
        self.originalTitle = originalTitle
        self.chineseTitle = chineseTitle
        self.developers = developers
        self.released = released
        self.lengthMinutes = lengthMinutes
        self.rating = rating
        self.synopsis = synopsis
        self.synopsisTranslation = synopsisTranslation
        self.tags = tags
        self.screenshots = screenshots
        self.characters = characters
        self.fetchedAt = fetchedAt
    }

    /// 刷新资料后沿用旧的译文（原文没变的话）。
    public func keepingTranslation(from old: GameMetadata?) -> GameMetadata {
        var copy = self
        if let old, old.synopsis == synopsis { copy.synopsisTranslation = old.synopsisTranslation }
        return copy
    }

    /// 翻译简介时用的术语表：游戏自己的术语表，加上 原名 → 中文名。
    public func synopsisGlossary(merging glossary: [String: String]) -> [String: String] {
        var result = glossary
        if let original = originalTitle, let chinese = chineseTitle, result[original] == nil {
            result[original] = chinese
        }
        return result
    }

    /// “2010年3月26日”“2010年3月”“2010年”；未定时返回“未定”。
    public var releasedText: String? {
        guard let released, !released.isEmpty else { return nil }
        let parts = released.split(separator: "-").compactMap { Int($0) }
        switch parts.count {
        case 3: return "\(parts[0])年\(parts[1])月\(parts[2])日"
        case 2: return "\(parts[0])年\(parts[1])月"
        case 1: return "\(parts[0])年"
        default: return released.uppercased() == "TBA" ? "未定" : released
        }
    }

    /// “约 52 小时”；不到一小时按分钟算。
    public var lengthText: String? {
        guard let lengthMinutes, lengthMinutes > 0 else { return nil }
        if lengthMinutes < 60 { return "约 \(lengthMinutes) 分钟" }
        return "约 \(Int((Double(lengthMinutes) / 60).rounded())) 小时"
    }

    /// 换成十分制：86.9 → “8.7”。
    public var ratingText: String? {
        guard let rating, rating > 0 else { return nil }
        return String(format: "%.1f", rating / 10)
    }
}
