// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import KazusaCore

@Suite struct CoverTests {
    static func makePNG(width: Int, height: Int) -> Data? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(red: 1, green: 0.5, blue: 0.7, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    @Test func cleansTitleForSearch() {
        let q = VNDB.searchQueries(for: "素晴らしき日々HD版")
        #expect(q.first == "素晴らしき日々HD版")
        #expect(q.contains("素晴らしき日々"))

        #expect(VNDB.searchQueries(for: "【汉化】白色相簿2 v1.01").contains("白色相簿2"))
        #expect(VNDB.searchQueries(for: "素晴らしき日々～不連続存在～").contains("素晴らしき日々"))
        #expect(VNDB.searchQueries(for: "WHITE ALBUM2") == ["WHITE ALBUM2"])
    }

    @Test func parsesSearchResponse() throws {
        let json = """
        {"more":false,"results":[
          {"id":"v3144","title":"Subarashiki Hibi","alttitle":"素晴らしき日々","released":"2010-03-26",
           "image":{"url":"https://t.vndb.org/cv/17/90017.jpg","sexual":0,"violence":0}},
          {"id":"v1","title":"Lewd","image":{"url":"https://t.vndb.org/cv/1/1.jpg","sexual":2,"violence":0}},
          {"id":"v2","title":"No image","image":null}
        ]}
        """
        let entries = try VNDB.parse(Data(json.utf8))
        #expect(entries.map(\.id) == ["v3144", "v1", "v2"])
        #expect(entries[0].displayTitle == "素晴らしき日々")
        #expect(entries[0].hasSafeImage)
        #expect(!entries[1].hasSafeImage)
        #expect(!entries[2].hasSafeImage)
    }

    @Test func ranksLocalCoverFiles() {
        let paths = ["BGI.exe", "sysgrp.arc", "system/button_cover_small.png", "補丁＆附件/package.jpg", "cover.png", "readme.txt"]
        #expect(LocalCoverFinder.bestCandidate(relativePaths: paths) == "cover.png")
        #expect(LocalCoverFinder.bestCandidate(relativePaths: ["BGI.exe", "icon.ico"]) == nil)
    }

    @Test func storeRejectsNonImages() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kazusa-covers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CoverStore(directory: dir)
        let id = UUID()
        #expect(throws: CoverError.notAnImage) { try store.save(Data("<html>".utf8), for: id) }
        #expect(!store.hasCover(for: id))

        let png = try #require(Self.makePNG(width: 32, height: 32))
        try store.save(png, for: id)
        #expect(store.data(for: id) == png)
        store.remove(for: id)
        #expect(!store.hasCover(for: id))
    }

    @Test func decodesOldLibraryWithoutVNDBID() throws {
        let game = Game(title: "x", directory: URL(fileURLWithPath: "/tmp"), executable: "a.exe", engine: .bgi, locale: .japanese)
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(game)) as? [String: Any])
        object.removeValue(forKey: "vndbID")
        let decoded = try JSONDecoder().decode(Game.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.vndbID == nil)
        #expect(decoded.title == "x")
    }
}

@Suite struct MetadataTests {
    @Test func parsesDetailsResponse() throws {
        let json = """
        {"more":false,"results":[{"id":"v3144","title":"Subarashiki Hibi ~Furenzoku Sonzai~",
          "alttitle":"素晴らしき日々～不連続存在～",
          "titles":[
            {"lang":"en","main":false,"official":true,"title":"Wonderful Everyday"},
            {"lang":"ja","main":true,"official":true,"title":"素晴らしき日々～不連続存在～"},
            {"lang":"zh-Hant","main":false,"official":true,"title":"美好的每一天（繁）"},
            {"lang":"zh-Hans","main":false,"official":false,"title":"美好的每一天～不连续存在～"}],
          "released":"2010-03-26",
          "description":"One day, [b]Yuki[/b] sees a doll.\\n\\n[spoiler]Secret ending.[/spoiler]\\n\\n\\n[From [url=https://store.steampowered.com/app/658620/]Steam[/url]]",
          "developers":[{"id":"p1040","name":"KeroQ","original":"ケロQ"},{"id":"p2","name":"Makura","original":null}],
          "rating":86.9,"length_minutes":3103}]}
        """
        let m = try #require(try VNDB.parseDetails(Data(json.utf8)))
        #expect(m.vndbID == "v3144")
        #expect(m.originalTitle == "素晴らしき日々～不連続存在～")
        #expect(m.chineseTitle == "美好的每一天～不连续存在～")
        #expect(m.developers == ["ケロQ", "Makura"])
        #expect(m.synopsis == "One day, Yuki sees a doll.\n\n[From Steam]")
        #expect(m.releasedText == "2010年3月26日")
        #expect(m.lengthText == "约 52 小时")
        #expect(m.ratingText == "8.7")
    }

    @Test func handlesSparseDetails() throws {
        let json = #"{"more":false,"results":[{"id":"v9","title":"Doujin","released":"TBA","description":null,"rating":null,"length_minutes":null}]}"#
        let m = try #require(try VNDB.parseDetails(Data(json.utf8)))
        #expect(m.originalTitle == "Doujin")
        #expect(m.chineseTitle == nil)
        #expect(m.developers.isEmpty)
        #expect(m.synopsis == nil)
        #expect(m.releasedText == "未定")
        #expect(m.lengthText == nil)
        #expect(m.ratingText == nil)
        #expect(try VNDB.parseDetails(Data(#"{"more":false,"results":[]}"#.utf8)) == nil)
    }

    @Test func filtersTagsAndScreenshots() throws {
        let json = #"""
        {"results":[{"id":"v1","title":"T","tags":[
          {"name":"Low","rating":1.6,"spoiler":0,"category":"cont"},
          {"name":"Drama","rating":2.8,"spoiler":0,"category":"cont"},
          {"name":"Twist","rating":3.0,"spoiler":2,"category":"cont"},
          {"name":"Sex","rating":3.0,"spoiler":0,"category":"ero"},
          {"name":"Weak","rating":0.5,"spoiler":0,"category":"cont"}],
         "screenshots":[
          {"url":"https://t.vndb.org/sf/1.jpg","thumbnail":"https://t.vndb.org/sf.t/1.jpg","sexual":0,"violence":0},
          {"url":"https://t.vndb.org/sf/2.jpg","thumbnail":"https://t.vndb.org/sf.t/2.jpg","sexual":1.5,"violence":0}]}]}
        """#
        let m = try #require(try VNDB.parseDetails(Data(json.utf8)))
        #expect(m.tags == ["Drama", "Low"])
        #expect(m.screenshots?.map(\.url.lastPathComponent) == ["1.jpg"])
    }

    @Test func picksMainCharactersWithoutSpoilers() throws {
        let json = #"""
        {"results":[
          {"id":"c3","name":"Side","original":null,"image":null,"vns":[{"id":"v1","role":"side","spoiler":0}]},
          {"id":"c2","name":"Heroine","original":"ヒロイン","image":{"url":"https://t.vndb.org/ch/2.jpg","sexual":1.2,"violence":0},
           "vns":[{"id":"v1","role":"primary","spoiler":0}]},
          {"id":"c4","name":"Secret","original":null,"image":null,"vns":[{"id":"v1","role":"primary","spoiler":2}]},
          {"id":"c1","name":"Hero","original":null,"image":{"url":"https://t.vndb.org/ch/1.jpg","sexual":0,"violence":0},
           "vns":[{"id":"v9","role":"side","spoiler":0},{"id":"v1","role":"main","spoiler":0}]}]}
        """#
        let chars = try VNDB.parseCharacters(Data(json.utf8), vnID: "v1")
        #expect(chars.map(\.id) == ["c1", "c2"])
        #expect(chars[0].isProtagonist && chars[0].imageURL != nil)
        #expect(chars[1].imageURL == nil) // 擦边图不留
    }

    @Test func formatsPartialDates() {
        #expect(GameMetadata(vndbID: "v1", released: "2010-03").releasedText == "2010年3月")
        #expect(GameMetadata(vndbID: "v1", released: "2010").releasedText == "2010年")
        #expect(GameMetadata(vndbID: "v1", lengthMinutes: 45).lengthText == "约 45 分钟")
    }

    @Test func decodesOldLibraryWithoutMetadata() throws {
        let game = Game(title: "x", directory: URL(fileURLWithPath: "/tmp"), executable: "a.exe", engine: .bgi, locale: .japanese,
                        vndbID: "v1", metadata: GameMetadata(vndbID: "v1", developers: ["A"]))
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(game)) as? [String: Any])
        #expect(object["metadata"] != nil)
        object.removeValue(forKey: "metadata")
        let decoded = try JSONDecoder().decode(Game.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.metadata == nil)
        #expect(decoded.vndbID == "v1")
    }
}

@Suite struct SynopsisTranslationTests {
    @Test func keepsTranslationOnlyWhenSynopsisUnchanged() {
        let old = GameMetadata(vndbID: "v1", synopsis: "A girl.", synopsisTranslation: "一个女孩。")
        #expect(GameMetadata(vndbID: "v1", synopsis: "A girl.").keepingTranslation(from: old).synopsisTranslation == "一个女孩。")
        #expect(GameMetadata(vndbID: "v1", synopsis: "A boy.").keepingTranslation(from: old).synopsisTranslation == nil)
        #expect(GameMetadata(vndbID: "v1", synopsis: "A girl.").keepingTranslation(from: nil).synopsisTranslation == nil)
    }

    @Test func glossaryAddsTitleWithoutOverridingUser() {
        let m = GameMetadata(vndbID: "v1", originalTitle: "素晴らしき日々", chineseTitle: "美好的每一天")
        #expect(m.synopsisGlossary(merging: ["由岐": "由岐"]) == ["由岐": "由岐", "素晴らしき日々": "美好的每一天"])
        #expect(m.synopsisGlossary(merging: ["素晴らしき日々": "美妙的日子"])["素晴らしき日々"] == "美妙的日子")
    }

    @Test func synopsisPromptUsesTargetLanguageAndNoContext() throws {
        let provider = LLMProviderConfig(name: "t", style: .openAICompatible, baseURL: "https://example.com/v1", model: "m")
        let translator = LLMTranslator(provider: provider, prompt: .synopsis(targetLanguage: "繁體中文"), apiKey: nil)
        #expect(translator.systemPrompt().contains("游戏简介翻译成繁體中文"))
        let request = TranslationRequest(text: "Hello.", context: [("a", "甲")], glossary: [:])
        #expect(!translator.userMessage(request).contains("上文"))
    }
}
