// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Compression
import Foundation
import Testing
@testable import KazusaCore

/// 在测试里拼出 XP3 封包。格式见 `XP3Archive`。
enum XP3Builder {
    struct File {
        var name: String
        var data: Data
        var compressed = true
    }

    static func le(_ value: UInt64, _ bytes: Int = 8) -> [UInt8] {
        (0..<bytes).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
    }

    static func chunk(_ name: String, _ body: [UInt8]) -> [UInt8] {
        Array(name.utf8) + le(UInt64(body.count)) + body
    }

    /// 带 zlib 头和 Adler-32 校验的 zlib 流（krkr2 用 zlib 的 uncompress，会校验）。
    static func zlib(_ input: [UInt8]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: input.count + 1024)
        let n = compression_encode_buffer(&output, output.count, input, input.count, nil, COMPRESSION_ZLIB)
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in input { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        let adler = b << 16 | a
        return [0x78, 0x9C] + output.prefix(n) + [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: adler >> $0) }
    }

    static func build(_ files: [File], compressIndex: Bool = true, version2: Bool = true) -> Data {
        var out = XP3Archive.magic
        let headerSize = version2 ? 11 + 8 + 4 + 1 + 8 + 8 : 11 + 8
        var body: [UInt8] = []
        var index: [UInt8] = []
        for file in files {
            let raw = [UInt8](file.data)
            let stored = file.compressed ? zlib(raw) : raw
            let offset = UInt64(headerSize + body.count)
            body += stored
            let name = Array(file.name.utf16)
            let info = le(0, 4) + le(UInt64(raw.count)) + le(UInt64(stored.count)) + le(UInt64(name.count), 2)
                + name.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
            let segm = le(file.compressed ? 1 : 0, 4) + le(offset) + le(UInt64(raw.count)) + le(UInt64(stored.count))
            index += chunk("File", chunk("info", info) + chunk("segm", segm) + chunk("adlr", le(0, 4)))
        }
        let indexOffset = UInt64(headerSize + body.count)
        if version2 {
            // 版本 2：头后面先是一段空的、带“还有下一段”标记的索引，指向真正的索引。
            out += le(0x17) + le(1, 4) + [0x80] + le(0) + le(indexOffset)
        } else {
            out += le(indexOffset)
        }
        out += body
        if compressIndex {
            let packed = zlib(index)
            out += [0x01] + le(UInt64(packed.count)) + le(UInt64(index.count)) + packed
        } else {
            out += [0x00] + le(UInt64(index.count)) + index
        }
        return Data(out)
    }
}

@Suite struct KiriKiriTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let script = Data("// startup\nScripts.execStorage(\"system/Initialize.tjs\");\n".utf8)

    @Test(arguments: [(true, true), (true, false), (false, true), (false, false)])
    func readsArchive(compressIndex: Bool, version2: Bool) throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("data.xp3")
        try XP3Builder.build([
            .init(name: "system/Config.tjs", data: Data("config".utf8), compressed: false),
            .init(name: "startup.tjs", data: script),
        ], compressIndex: compressIndex, version2: version2).write(to: url)
        let archive = try XP3Archive(url: url)
        #expect(archive.entries.map(\.name) == ["system/Config.tjs", "startup.tjs"])
        #expect(try archive.read(#require(archive.entry(named: "STARTUP.TJS"))) == script)
        #expect(try archive.read(#require(archive.entry(named: "system/Config.tjs"))) == Data("config".utf8))
    }

    @Test func rejectsGarbage() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("data.xp3")
        try Data("PK\u{3}\u{4} not an xp3".utf8).write(to: url)
        #expect(throws: XP3Archive.ReadError.self) { try XP3Archive(url: url) }
        // 索引位置指到文件外面。
        try Data(XP3Archive.magic + XP3Builder.le(1 << 40)).write(to: url)
        #expect(throws: XP3Archive.ReadError.self) { try XP3Archive(url: url) }
    }

    @Test func readiness() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(KiriKiri.readiness(of: dir) == .noData)

        let xp3 = dir.appendingPathComponent("data.xp3")
        try XP3Builder.build([.init(name: "startup.tjs", data: script)]).write(to: xp3)
        #expect(KiriKiri.readiness(of: dir) == .ready)

        // 加密的游戏：startup.tjs 解出来是乱码。
        var rng = SystemRandomNumberGenerator()
        let noise = Data((0..<4096).map { _ in UInt8.random(in: 0...255, using: &rng) })
        try XP3Builder.build([.init(name: "startup.tjs", data: noise)]).write(to: xp3)
        #expect(KiriKiri.readiness(of: dir) == .encrypted)

        // 文件名被打乱（索引里找不到 startup.tjs）也算加密。
        try XP3Builder.build([.init(name: "a1b2c3", data: script)]).write(to: xp3)
        #expect(KiriKiri.readiness(of: dir) == .encrypted)

        // 散装的 startup.tjs 优先。
        try script.write(to: dir.appendingPathComponent("startup.tjs"))
        #expect(KiriKiri.readiness(of: dir) == .ready)
    }

    @Test func scriptDetection() {
        #expect(KiriKiri.looksLikeScript(Data("var a = 1;\r\n\t// コメント\n".utf8)))
        var utf16 = Data([0xFF, 0xFE])
        utf16.append("@wait time=100\n".data(using: .utf16LittleEndian)!)
        #expect(KiriKiri.looksLikeScript(utf16))
        #expect(KiriKiri.looksLikeScript(Data([0xFE, 0xFE, 0x01, 0xFF, 0xFE, 0x12, 0x00])))
        #expect(!KiriKiri.looksLikeScript(Data([0x00, 0x13, 0x88, 0x02, 0x7F, 0x05])))
        #expect(!KiriKiri.looksLikeScript(Data()))
    }

    @Test func arguments() {
        var g = Game(title: "t", directory: URL(fileURLWithPath: "/Games/ある日"), executable: "game.exe",
                     engine: .kirikiri, locale: .japanese)
        g.arguments = ["--", "-debug=yes"]
        #expect(KiriKiri.arguments(for: g) == ["--game", "/Games/ある日", "--", "-debug=yes"])
        #expect(NativeEngines.launchArguments(for: g) == KiriKiri.arguments(for: g))
    }

    @Test func findsRepoBinary() {
        // 仓库里提交了 prebuilt/krkr2.app；Intel Mac 上不可用。
        #expect((KiriKiri.binary() != nil) == SystemCheck.isAppleSilicon)
    }
}
