// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation
import Testing
@testable import KazusaCore

@Suite struct NativeBackendTests {
    private func game(_ engine: EngineKind, backend: GameBackend? = nil, locale: GameLocale = .japanese,
                      directory: URL = URL(fileURLWithPath: "/tmp/game")) -> Game {
        Game(title: "t", directory: directory, executable: "", engine: engine, locale: locale, backend: backend)
    }

    @Test func automaticPrefersNativeEngine() {
        #expect(game(.nscripter).resolvedBackend(nativeAvailable: true) == .native)
        #expect(game(.nscripter).resolvedBackend(nativeAvailable: false) == .wine)
        #expect(game(.kirikiri).resolvedBackend(nativeAvailable: true) == .native)
        #expect(game(.bgi).resolvedBackend(nativeAvailable: true) == .wine)
        #expect(game(.nscripter, backend: .wine).resolvedBackend(nativeAvailable: true) == .wine)
        #expect(game(.nscripter, backend: .native).resolvedBackend(nativeAvailable: false) == .native)
    }

    @Test func oldLibraryDecodesAsAutomatic() throws {
        let data = try JSONEncoder().encode(game(.nscripter))
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["backend"] = nil
        let decoded = try JSONDecoder().decode(Game.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.backend == nil)
    }

    @Test func encodingDetection() {
        let utf8 = Data("*define\ncaption \"测试\"\n".utf8)
        #expect(ONScripter.detectEncoding(sample: utf8, locale: .japanese) == .utf8)
        // 截断在多字节字符中间也算 UTF-8。
        #expect(ONScripter.detectEncoding(sample: utf8.prefix(utf8.count - 6), locale: .japanese) == .utf8)
        let gbk = Data([0x2A, 0x64, 0x0A, 0xC4, 0xE3, 0xBA, 0xC3]) // "*d\n你好"（GBK）
        #expect(ONScripter.detectEncoding(sample: gbk, locale: .simplifiedChinese) == .gbk)
        let sjis = Data([0x82, 0xB1, 0x82, 0xF1, 0x82, 0xC9, 0x82, 0xBF, 0x82, 0xCD]) // こんにちは
        #expect(ONScripter.detectEncoding(sample: sjis, locale: .japanese) == .sjis)
        // 纯 ASCII 看不出来，按区域。
        #expect(ONScripter.detectEncoding(sample: Data("*define\n".utf8), locale: .japanese) == .sjis)
        #expect(ONScripter.detectEncoding(sample: nil, locale: .traditionalChinese) == .gbk)
    }

    @Test func readsEncryptedNscriptDat() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = Data("caption \"日本語\"\n".utf8)
        try Data(script.map { $0 ^ 0x84 }).write(to: dir.appendingPathComponent("nscript.dat"))
        #expect(ONScripter.scriptSample(in: dir) == script)
        // 0.txt 优先于 nscript.dat。
        try Data("plain".utf8).write(to: dir.appendingPathComponent("0.txt"))
        #expect(ONScripter.scriptSample(in: dir) == Data("plain".utf8))
    }

    @Test func fontAndArguments() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fonts = dir.appendingPathComponent("fonts")
        try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for font in [FontSubstitutes.hiraginoSans, FontSubstitutes.hiraginoSansGB] {
            FileManager.default.createFile(atPath: fonts.appendingPathComponent(font.file).path, contents: Data())
        }
        var g = game(.nscripter, locale: .japanese, directory: dir)
        #expect(ONScripter.font(for: g, fontsDirectory: fonts)?.lastPathComponent == FontSubstitutes.hiraginoSans.file)
        g.locale = .simplifiedChinese
        let font = ONScripter.font(for: g, fontsDirectory: fonts)
        #expect(font?.lastPathComponent == FontSubstitutes.hiraginoSansGB.file)

        g.arguments = ["--fullscreen"]
        #expect(ONScripter.arguments(for: g, encoding: .gbk, font: font)
                == ["--root", dir.path, "--enc:gbk", "--font", font!.path, "--fullscreen"])

        // 游戏自带 default.ttf 时不指定字体。
        FileManager.default.createFile(atPath: dir.appendingPathComponent("default.ttf").path, contents: Data())
        #expect(ONScripter.font(for: g, fontsDirectory: fonts) == nil)
    }
}
