// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation

extension VNDB {
    static func detailsRequestBody(id: String) throws -> Data {
        let body: [String: Any] = [
            "filters": ["id", "=", id],
            "fields": "title,alttitle,titles.lang,titles.title,titles.main,titles.official,released,description,"
                + "developers.name,developers.original,rating,length_minutes,"
                + "tags.name,tags.rating,tags.spoiler,tags.category,"
                + "screenshots.url,screenshots.thumbnail,screenshots.sexual,screenshots.violence",
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
            var tags: [Tag]?
            var screenshots: [Screenshot]?
        }
        struct Tag: Decodable {
            var name: String
            var rating: Double
            var spoiler: Int
            var category: String
        }
        struct Screenshot: Decodable {
            var url: URL
            var thumbnail: URL
            var sexual: Double
            var violence: Double
        }
        var results: [Item]
    }

    static let characterEndpoint = URL(string: "https://api.vndb.org/kana/character")!

    static func charactersRequestBody(id: String) throws -> Data {
        let body: [String: Any] = [
            "filters": ["vn", "=", ["id", "=", id]],
            "fields": "name,original,image.url,image.sexual,image.violence,vns.id,vns.role,vns.spoiler",
            "results": 50,
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    private struct CharactersResponse: Decodable {
        struct Item: Decodable {
            struct Image: Decodable {
                var url: URL
                var sexual: Double
                var violence: Double
            }
            struct VN: Decodable {
                var id: String
                var role: String
                var spoiler: Int
            }
            var id: String
            var name: String
            var original: String?
            var image: Image?
            var vns: [VN]
        }
        var results: [Item]
    }

    /// 只留这部作品里的主角和主要角色，剧透角色不要；主角排前面。
    static func parseCharacters(_ data: Data, vnID: String) throws -> [GameMetadata.Character] {
        let items = try JSONDecoder().decode(CharactersResponse.self, from: data).results
        let picked: [(GameMetadata.Character, Int)] = items.compactMap { item in
            guard let vn = item.vns.first(where: { $0.id == vnID }), vn.spoiler == 0,
                  let rank = ["main", "primary"].firstIndex(of: vn.role) else { return nil }
            let safe = item.image.flatMap { $0.sexual < 1 && $0.violence < 1 ? $0.url : nil }
            return (GameMetadata.Character(id: item.id, name: item.name, original: item.original, imageURL: safe,
                                           isProtagonist: rank == 0), rank)
        }
        return picked.enumerated().sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }.map(\.element.0)
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
        // 成人（ero）标签不展示；技术类（tech）对玩家没意义。
        let tags = (item.tags ?? []).filter { $0.spoiler == 0 && $0.category == "cont" && $0.rating >= 1.5 }
            .sorted { $0.rating > $1.rating }.prefix(10).map(\.name)
        let screenshots = (item.screenshots ?? []).filter { $0.sexual < 1 && $0.violence < 1 }
            .map { GameMetadata.Screenshot(url: $0.url, thumbnail: $0.thumbnail) }
        return GameMetadata(vndbID: item.id, originalTitle: original, chineseTitle: chinese, developers: developers,
                            released: item.released, lengthMinutes: item.length_minutes, rating: item.rating,
                            synopsis: synopsis, tags: Array(tags), screenshots: screenshots, fetchedAt: fetchedAt)
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
        async let detailsData = post(try detailsRequestBody(id: id), session: session)
        async let charactersData = post(try charactersRequestBody(id: id), to: characterEndpoint, session: session)
        guard var metadata = try parseDetails(try await detailsData) else { throw CoverError.notFound }
        metadata.characters = try parseCharacters(try await charactersData, vnID: metadata.vndbID)
        return metadata
    }
}
