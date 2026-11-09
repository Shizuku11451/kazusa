// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation

/// 一条 VNDB 视觉小说记录（只取封面需要的字段）。
public struct VNDBEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var alttitle: String?
    public var released: String?
    public var imageURL: URL?
    /// VNDB 用户投票的平均值，0 = 安全，1 = 擦边，2 = 露骨。
    public var imageSexual: Double
    /// 0 = 无，1 = 暴力，2 = 血腥。
    public var imageViolence: Double

    public init(id: String, title: String, alttitle: String? = nil, released: String? = nil,
                imageURL: URL? = nil, imageSexual: Double = 0, imageViolence: Double = 0) {
        self.id = id
        self.title = title
        self.alttitle = alttitle
        self.released = released
        self.imageURL = imageURL
        self.imageSexual = imageSexual
        self.imageViolence = imageViolence
    }

    /// 可以直接当封面展示（不含成人或血腥内容）。
    public var hasSafeImage: Bool {
        imageURL != nil && imageSexual < 1 && imageViolence < 1
    }

    public var displayTitle: String { alttitle ?? title }
    public var pageURL: URL { URL(string: "https://vndb.org/\(id)")! }
}

/// 用 VNDB（https://vndb.org，免费、无需密钥）的公开 API 按标题查封面。
///
/// 只会把搜索用的游戏标题发给 api.vndb.org。
public enum VNDB {
    static let endpoint = URL(string: "https://api.vndb.org/kana/vn")!

    /// 从游戏库里的标题生成几种搜索词：原样、去掉“HD版 / 汉化版 / 版本号 / 括号”等修饰后的。
    public static func searchQueries(for title: String) -> [String] {
        var queries: [String] = []
        func add(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if t.count >= 2, !queries.contains(t) { queries.append(t) }
        }
        add(title)

        var cleaned = title
        // 各种括号里的内容：【汉化】(v1.01) [DL版] 「」
        cleaned = cleaned.replacingOccurrences(of: #"[\[【(（「『<《][^\]】)）」』>》]*[\]】)）」』>》]"#, with: " ", options: .regularExpression)
        // 版本号
        cleaned = cleaned.replacingOccurrences(of: #"(?i)\bv(er)?\.?\s*\d+(\.\d+)*\b"#, with: " ", options: .regularExpression)
        // 发行版本 / 汉化相关的后缀
        let suffixes = ["HD版", "HD", "汉化版", "漢化版", "汉化", "漢化", "中文版", "简体中文版", "繁體中文版", "简中", "繁中",
                        "完全版", "通常版", "初回限定版", "限定版", "体験版", "体验版", "DL版", "パッケージ版", "リマスター版",
                        "Remastered", "Steam版", "Steam", "免安装版", "硬盘版"]
        for suffix in suffixes {
            cleaned = cleaned.replacingOccurrences(of: suffix, with: " ", options: [.caseInsensitive])
        }
        cleaned = cleaned.replacingOccurrences(of: #"[_\-]+"#, with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        add(cleaned)

        // 副标题前的主标题：素晴らしき日々～不連続存在～ → 素晴らしき日々
        if let range = cleaned.range(of: #"[～~〜:：\-—]"#, options: .regularExpression) {
            add(String(cleaned[..<range.lowerBound]))
        }
        return queries
    }

    static func requestBody(query: String, results: Int) throws -> Data {
        let body: [String: Any] = [
            "filters": ["search", "=", query],
            "fields": "title,alttitle,released,image.url,image.sexual,image.violence",
            "sort": "searchrank",
            "results": results,
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    private struct Response: Decodable {
        struct Item: Decodable {
            struct Image: Decodable {
                var url: URL?
                var sexual: Double?
                var violence: Double?
            }
            var id: String
            var title: String
            var alttitle: String?
            var released: String?
            var image: Image?
        }
        var results: [Item]
    }

    static func parse(_ data: Data) throws -> [VNDBEntry] {
        try JSONDecoder().decode(Response.self, from: data).results.map {
            VNDBEntry(id: $0.id, title: $0.title, alttitle: $0.alttitle, released: $0.released,
                      imageURL: $0.image?.url, imageSexual: $0.image?.sexual ?? 0, imageViolence: $0.image?.violence ?? 0)
        }
    }

    static func post(_ body: Data, session: URLSession) async throws -> Data {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Kazusa (https://github.com/Shizuku11451/kazusa)", forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw CoverError.http(http.statusCode) }
        return data
    }

    public static func search(_ query: String, results: Int = 10, session: URLSession = .shared) async throws -> [VNDBEntry] {
        try parse(try await post(try requestBody(query: query, results: results), session: session))
    }

    /// 依次用 `searchQueries` 搜索，返回第一个有安全封面的结果。
    /// `requireSafeImage` 为 false 时只要有结果就行（游戏已经有封面、只想拿资料时用）。
    public static func bestMatch(for title: String, requireSafeImage: Bool = true,
                                 session: URLSession = .shared) async throws -> VNDBEntry? {
        for query in searchQueries(for: title) {
            let entries = try await search(query, results: 5, session: session)
            if let hit = entries.first(where: { !requireSafeImage || $0.hasSafeImage }) { return hit }
        }
        return nil
    }

    public static func downloadImage(_ entry: VNDBEntry, session: URLSession = .shared) async throws -> Data {
        guard let url = entry.imageURL else { throw CoverError.notFound }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Kazusa (https://github.com/Shizuku11451/kazusa)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw CoverError.http(http.statusCode) }
        guard CoverStore.isImage(data) else { throw CoverError.notAnImage }
        return data
    }
}
