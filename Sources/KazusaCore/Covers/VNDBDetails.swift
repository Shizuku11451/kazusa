// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation

extension VNDB {
    static func detailsRequestBody(id: String) throws -> Data {
        let body: [String: Any] = [
            "filters": ["id", "=", id],
            "fields": "title,alttitle,titles.lang,titles.title,titles.main,titles.official,released,description,"
                + "developers.name,developers.original,rating,length_minutes",
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    private struct DetailsResponse: Decodable {
        struct Item: Decodable {
            struct Title: Decodable {
                var lang: String
                var title: String
                var main: Bool?
                var official: Bool?
            }
            struct Developer: Decodable {
                var name: String
                var original: String?
            }
            var id: String
            var title: String
            var alttitle: String?
            var titles: [Title]?
            var released: String?
            var description: String?
            var developers: [Developer]?
            var rating: Double?
            var length_minutes: Int?
        }
        var results: [Item]
    }

    static func parseDetails(_ data: Data, fetchedAt: Date = Date()) throws -> GameMetadata? {
        guard let item = try JSONDecoder().decode(DetailsResponse.self, from: data).results.first else { return nil }
        let titles = item.titles ?? []
        // 中文标题：简体优先，其次繁体；同一语言里官方译名优先。
        let chinese = ["zh-Hans", "zh-Hant", "zh"].lazy.compactMap { lang in
            titles.filter { $0.lang == lang }.sorted { ($0.official ?? false) && !($1.official ?? false) }.first?.title
        }.first
        let original = titles.first { $0.main == true }?.title ?? item.alttitle ?? item.title
        var developers: [String] = []
        for dev in item.developers ?? [] {
            let name = dev.original?.isEmpty == false ? dev.original! : dev.name
            if !developers.contains(name) { developers.append(name) }
        }
        let synopsis = item.description.map(cleanDescription).flatMap { $0.isEmpty ? nil : $0 }
        return GameMetadata(vndbID: item.id, originalTitle: original, chineseTitle: chinese, developers: developers,
                            released: item.released, lengthMinutes: item.length_minutes, rating: item.rating,
                            synopsis: synopsis, fetchedAt: fetchedAt)
    }

    /// 把 VNDB 简介里的 BBCode 去掉：剧透段落整段删掉，链接只留文字，其余标签去掉。
    public static func cleanDescription(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.replacingOccurrences(of: #"(?is)\[spoiler\].*?\[/spoiler\]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)\[url=[^\]]*\](.*?)\[/url\]"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)\[/?(b|i|u|s|raw|code|quote|url)\]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 按条目编号（如 "v3144"）拉取资料。
    public static func details(id: String, session: URLSession = .shared) async throws -> GameMetadata {
        let data = try await post(try detailsRequestBody(id: id), session: session)
        guard let metadata = try parseDetails(data) else { throw CoverError.notFound }
        return metadata
    }
}
