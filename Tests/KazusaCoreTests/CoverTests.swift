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
