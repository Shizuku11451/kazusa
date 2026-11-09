// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation
import Testing
@testable import KazusaCore

@Suite struct EngineDetectorTests {
    @Test(arguments: [
        (["data.xp3", "patch.xp3", "WA2.exe"], EngineKind.kirikiri),
        (["nscript.dat", "arc.nsa", "nscr.exe"], .nscripter),
        (["Scene.pck", "Gameexe.dat", "SiglusEngine.exe"], .siglus),
        (["Seen.txt", "Gameexe.ini", "RealLive.exe"], .reallive),
        (["BGI.exe", "sysgrp.arc", "data01000.arc"], .bgi),
        (["scene.int", "image.int", "cs2.exe"], .catSystem2),
        (["bn.ypf", "pac/ysbin.ypf"], .yuris),
        (["root.pfs", "game.exe"], .artemis),
        (["GameData/data0.pack", "game.exe"], .qlie),
        (["Rance10.ain", "Rance10CG.afa"], .system4),
        (["UnityPlayer.dll", "Game_Data/globalgamemanagers"], .unity),
        (["renpy/__init__.py", "game/archive.rpa"], .renpy),
        (["www/js/rpg_core.js", "Game.exe"], .rpgMakerMV),
        (["tyrano/libs.js", "data/scenario/first.ks"], .tyrano),
        (["Data.wolf", "Game.exe"], .wolfRPG),
    ])
    func detectsEngine(paths: [String], expected: EngineKind) {
        let result = EngineDetector.detect(relativePaths: paths)
        #expect(result.engine == expected)
        #expect(result.confidence > 0.5)
        #expect(!result.evidence.isEmpty)
    }

    @Test func unknownWhenNoMarkers() {
        let result = EngineDetector.detect(relativePaths: ["game.exe", "readme.txt"])
        #expect(result.engine == .unknown)
        #expect(result.confidence == 0)
    }

    @Test func caseInsensitive() {
        #expect(EngineDetector.detect(relativePaths: ["DATA.XP3"]).engine == .kirikiri)
    }

    @Test func extensionMustMatchExactly() {
        // "foo.xp3.bak" 不应被当成 xp3 封包。
        #expect(EngineDetector.detect(relativePaths: ["foo.xp3.bak"]).engine == .unknown)
    }
}

@Suite struct GameInspectorTests {
    @Test func ranksMainExecutableFirst() {
        let ranked = GameInspector.rankExecutables(
            paths: ["config.exe", "WA2.exe", "tools/unins000.exe", "環境設定.exe"],
            directoryName: "WA2"
        )
        #expect(ranked.first == "WA2.exe")
    }

    /// 真实的汉化移植版目录结构（只保留文件名）。
    @Test func followsReadmeFileNameHint() {
        let paths = [
            "BGI_patch.exe", "BGI_patch.exe 启动游戏 汉化移植v1.01版本.txt", "BGI-CHS.exe", "BGI.exe",
            "BHVC.exe", "Uninstaller.exe", "README.txt", "补丁＆附件/汉化移植v1.01修正补丁/BGI_patch.exe",
        ]
        #expect(GameInspector.rankExecutables(paths: paths, directoryName: "素晴らしき日々HD版").first == "BGI_patch.exe")
        // 没有提示文件时，汉化程序排在原版前面。
        let noHint = paths.filter { !$0.hasSuffix(".txt") && !$0.contains("patch") }
        #expect(GameInspector.rankExecutables(paths: noHint, directoryName: "x").first == "BGI-CHS.exe")
    }

    @Test func guessesChineseForTranslatedRelease() {
        #expect(GameInspector.guessLocale(title: "白色相簿2 汉化硬盘版", paths: ["WA2.exe"]) == .simplifiedChinese)
        #expect(GameInspector.guessLocale(title: "WA2_CHT", paths: []) == .traditionalChinese)
    }

    @Test func guessesJapaneseWhenKanaPresent() {
        #expect(GameInspector.guessLocale(title: "ホワイトアルバム2", paths: ["WA2.exe"]) == .japanese)
    }

    @Test func defaultsToChinese() {
        #expect(GameInspector.guessLocale(title: "WA2", paths: ["WA2.exe"]) == .simplifiedChinese)
    }

    @Test func scansRealDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kazusa-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["data.xp3", "game.exe", "sub/patch.xp3"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data("x".utf8))
        }
        let inspection = GameInspector.inspect(directory: dir)
        #expect(inspection.engine.engine == .kirikiri)
        #expect(inspection.suggestedExecutable == "game.exe")
    }
}

@Suite struct WineConfigTests {
    @Test func environmentSetsLocaleAndPrefix() {
        let runtime = WineRuntime(wineBinary: URL(fileURLWithPath: "/opt/wine/bin/wine"), source: .custom)
        let env = WineEnvironment.make(
            runtime: runtime,
            prefix: URL(fileURLWithPath: "/tmp/pfx"),
            locale: .japanese,
            extra: ["WINEDLLOVERRIDES": "d3d9=n,b", "FOO": "1"],
            inherited: ["HOME": "/Users/me", "SECRET": "x"]
        )
        #expect(env["LANG"] == "ja_JP.UTF-8")
        #expect(env["LC_ALL"] == "ja_JP.UTF-8")
        #expect(env["WINEPREFIX"] == "/tmp/pfx")
        #expect(env["HOME"] == "/Users/me")
        #expect(env["SECRET"] == nil)
        #expect(env["PATH"]?.hasPrefix("/opt/wine/bin:") == true)
        #expect(env["WINEDLLOVERRIDES"] == "winemenubuilder.exe=d;d3d9=n,b")
        #expect(env["FOO"] == "1")
    }

    @Test func fontRegistryPicksFaceByLocale() {
        let ja = FontSubstitutes.registryFile(locale: .japanese)
        #expect(ja.hasPrefix("Windows Registry Editor Version 5.00"))
        #expect(ja.contains("\"ＭＳ ゴシック\"=\"Hiragino Sans W3\""))
        #expect(ja.contains("FontLink\\SystemLink]"))
        #expect(ja.contains("\"Tahoma\"=hex(7):"))

        let zh = FontSubstitutes.registryFile(locale: .simplifiedChinese)
        #expect(zh.contains("\"宋体\"=\"Hiragino Sans GB W3\""))
        // 旧版本写错的默认值视为“自动”，用户自定义的字体名照用。
        #expect(FontSubstitutes.targetFace(for: .simplifiedChinese, override: "Hiragino Sans GB") == "Hiragino Sans GB W3")
        #expect(FontSubstitutes.targetFace(for: .japanese, override: "Osaka") == "Osaka")
    }

    @Test func multiStringEncoding() {
        // "a" 0 "" 0 → 61 00 00 00 00 00
        #expect(FontSubstitutes.multiString(["a"]) == "hex(7):61,00,00,00,00,00")
    }

    @Test func gameDefaultsFollowLocale() {
        let ja = Game(title: "a", directory: URL(fileURLWithPath: "/g"), executable: "a.exe", engine: .unknown, locale: .japanese)
        let zh = Game(title: "b", directory: URL(fileURLWithPath: "/g"), executable: "b.exe", engine: .unknown, locale: .simplifiedChinese)
        #expect(ja.translation.enabled)
        #expect(!zh.translation.enabled)
        #expect(ja.prefixName == "default-ja")
        #expect(zh.prefixName == "default-zhs")
    }
}

@Suite struct PrefixFontTests {
    @Test func copiesGameFontsIntoPrefix() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kz-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let game = tmp.appendingPathComponent("game")
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: game.appendingPathComponent("font.ttf"))
        try Data().write(to: game.appendingPathComponent("game.exe"))

        let prefix = WinePrefix(name: "p", paths: KazusaPaths(root: tmp))
        let first = try prefix.installFonts(from: game, tag: "1234")
        #expect(first.map(\.lastPathComponent) == ["kazusa-1234-font.ttf"])
        #expect(try prefix.installFonts(from: game, tag: "1234").isEmpty) // 已经装过
        #expect(try prefix.installFonts(from: game, tag: "5678").isEmpty) // 同一字体换了 tag 也不重复装
    }

    @Test func stableHash() {
        #expect("abc".hashValueStable == 0xe71fa2190541574b)
    }
}

@Suite struct LegacyTextTests {
    @Test func decodesShiftJISOutput() {
        let data = "現在のコード ページ: 932".data(using: .shiftJIS)!
        #expect(LegacyText.decode(data) == "現在のコード ページ: 932")
    }

    @Test func prefersUTF8() {
        #expect(LegacyText.decode(Data("冬馬かずさ".utf8)) == "冬馬かずさ")
    }
}

@Suite struct RosettaWoW64FixTests {
    @Test func parsesWineVersion() {
        #expect(RosettaWoW64Fix.wineVersion(fromVersionOutput: "wine-11.21 (Staging)\n") == "11.21")
        #expect(RosettaWoW64Fix.wineVersion(fromVersionOutput: "wine-11.0") == "11.0")
        #expect(RosettaWoW64Fix.wineVersion(fromVersionOutput: "garbage") == nil)
    }

    @Test func findsBundledDLLForKnownVersion() {
        let roots = RosettaWoW64Fix.searchRoots(paths: KazusaPaths(root: URL(fileURLWithPath: "/nonexistent")))
        #expect(RosettaWoW64Fix.patchedDLL(version: "11.21", searchRoots: roots) != nil)
        #expect(RosettaWoW64Fix.patchedDLL(version: "1.0", searchRoots: roots) == nil)
    }

    @Test func installBacksUpOriginalOnce() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("kz-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let fixed = tmp.appendingPathComponent("fixed.dll")
        let target = tmp.appendingPathComponent("wow64cpu.dll")
        try Data("fixed".utf8).write(to: fixed)
        try Data("orig".utf8).write(to: target)

        #expect(try RosettaWoW64Fix.install(fixed, over: target))
        #expect(try !RosettaWoW64Fix.install(fixed, over: target)) // 已是修复版
        #expect(try Data(contentsOf: target) == Data("fixed".utf8))
        // 再被 wineboot 覆盖后重新修复，备份仍是最初的原版。
        try Data("orig2".utf8).write(to: target)
        #expect(try RosettaWoW64Fix.install(fixed, over: target))
        #expect(try Data(contentsOf: target.appendingPathExtension("orig")) == Data("orig".utf8))
    }
}
