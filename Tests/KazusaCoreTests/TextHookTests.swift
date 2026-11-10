// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation
import Testing
@testable import KazusaCore

@Suite struct TextHookTests {
    static func peHeader(machine: UInt16) -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x100)
        bytes[0] = 0x4D; bytes[1] = 0x5A
        bytes[0x3C] = 0x80
        bytes[0x80] = 0x50; bytes[0x81] = 0x45
        bytes[0x84] = UInt8(machine & 0xFF); bytes[0x85] = UInt8(machine >> 8)
        return Data(bytes)
    }

    @Test func readsPEArchitecture() {
        #expect(PEImage.architecture(header: Self.peHeader(machine: 0x014C)) == .x86)
        #expect(PEImage.architecture(header: Self.peHeader(machine: 0x8664)) == .x64)
        #expect(PEImage.architecture(header: Self.peHeader(machine: 0xAA64)) == nil)
        #expect(PEImage.architecture(header: Data("not an exe".utf8)) == nil)
    }

    @Test func parsesEvents() {
        #expect(HookEvent.parse(#"{"type":"ready","pid":42}"#) == .ready(pid: 42))
        #expect(HookEvent.parse(#"{"type":"thread","id":"2a:5151f:0:0","hookcode":"HSX0:0@5151F:WA2.exe","name":"Leaf"}"#)
            == .thread(HookThread(id: "2a:5151f:0:0", hookcode: "HSX0:0@5151F:WA2.exe", name: "Leaf")))
        #expect(HookEvent.parse(#"{"type":"text","id":"a","text":"「雪が\n降ってる」"}"#)
            == .text(threadID: "a", text: "「雪が\n降ってる」"))
        #expect(HookEvent.parse(#"{"type":"info","level":4,"message":"Leaf"}"#) == .info(level: 4, message: "Leaf"))
        #expect(HookEvent.parse(#"{"type":"detached","pid":42}"#) == .detached(pid: 42))
        // LunaHost 打到标准输出的调试信息
        #expect(HookEvent.parse("1.000000 SHIFT_JIS 932") == nil)
        #expect(HookEvent.parse("") == nil)
        #expect(HookEvent.parse(#"{"type":"whatever"}"#) == nil)
    }

    @Test func cleansText() {
        #expect(HookText.clean("<R空港|ここ>で待ってる") == "空港で待ってる")
        #expect(HookText.clean("「雪が\n降ってる」\r\n") == "「雪が降ってる」")
        #expect(HookText.clean("　　冬馬かずさ　") == "冬馬かずさ")
    }

    @Test func filtersNonDialogue() {
        #expect(HookText.isDialogue("「雪が降ってる」"))
        #expect(HookText.isDialogue("かずさ"))
        #expect(!HookText.isDialogue("mv01"))
        #expect(!HookText.isDialogue("sepia.AMP"))
        #expect(!HookText.isDialogue(""))
    }

    @Test func picksBusiestThread() {
        var s = HookThreadSelector()
        s.register(HookThread(id: "name", hookcode: "H", name: "BGI"))
        s.register(HookThread(id: "dialogue", hookcode: "H", name: "BGI"))
        // 人名先到，暂时就用它
        #expect(s.accept(threadID: "name", text: "希実香") == "希実香")
        #expect(s.accept(threadID: "dialogue", text: "「ねえ、聞いてる？　今日はどこに行くの？」") == "「ねえ、聞いてる？　今日はどこに行くの？」")
        // 对白那一路字数领先之后，人名就不再送去翻译
        #expect(s.activeThreadID == "dialogue")
        #expect(s.accept(threadID: "name", text: "由岐") == nil)
        #expect(s.accept(threadID: "dialogue", text: "「屋上に行こうよ」") == "「屋上に行こうよ」")
    }

    @Test func dedupesAcrossThreadsAndRepeats() {
        // WA2：同一句话同时从带注音的一路和排好版的一路过来
        var s = HookThreadSelector()
        #expect(s.accept(threadID: "embed", text: "雪が\n降ってる") == "雪が降ってる")
        #expect(s.accept(threadID: "leaf", text: "雪が降ってる") == nil)
        #expect(s.accept(threadID: "embed", text: "雪が降ってる") == nil)
        #expect(s.accept(threadID: "embed", text: "mv01") == nil)
    }

    @Test func pinnedThreadWins() {
        var s = HookThreadSelector()
        _ = s.accept(threadID: "a", text: "とても長い長い文章がここに来る")
        s.pinnedThreadID = "b"
        #expect(s.accept(threadID: "a", text: "また長い文章") == nil)
        #expect(s.accept(threadID: "b", text: "短い") == "短い")
        s.remove(id: "b")
        #expect(s.pinnedThreadID == nil)
    }

    @Test func threadKeyIgnoresPidAndAddress() {
        let a = HookThread(id: "1234:4f7b0:41a2c3:0", hookcode: "HS-1C@44F7B0:WA2.exe", name: "")
        let b = HookThread(id: "5678:9a7b0:41a2c3:0", hookcode: "HS-1C@44F7B0:WA2.exe", name: "")
        #expect(HookThreadKey(a) == HookThreadKey(b))
        #expect(HookThreadKey(a) == HookThreadKey(hookcode: "HS-1C@44F7B0:WA2.exe", ctx: "41a2c3", ctx2: "0"))
        #expect(HookThreadKey(HookThread(id: "1234:4f7b0:41a2c4:0", hookcode: "HS-1C@44F7B0:WA2.exe", name: "")) != HookThreadKey(a))
        #expect(HookThreadKey(HookThread(id: "dialogue", hookcode: "H", name: "")) == nil)
        #expect(HookThreadKey(HookThread(id: "1:2:3:4", hookcode: "", name: "")) == nil)
    }

    @Test func remembersPinnedThreadAcrossLaunches() {
        // 第一次：手动指定人名那一路
        var first = HookThreadSelector()
        first.register(HookThread(id: "100:a:1:0", hookcode: "HS@A", name: "BGI"))
        first.register(HookThread(id: "100:a:2:0", hookcode: "HS@A", name: "BGI"))
        let saved = first.pin("100:a:2:0")
        #expect(saved == HookThreadKey(hookcode: "HS@A", ctx: "2", ctx2: "0"))

        // 第二次启动：进程号变了，同一路出现时自动指定
        var second = HookThreadSelector(remembered: saved)
        second.register(HookThread(id: "200:a:1:0", hookcode: "HS@A", name: "BGI"))
        #expect(second.pinnedThreadID == nil)
        second.register(HookThread(id: "200:a:2:0", hookcode: "HS@A", name: "BGI"))
        #expect(second.pinnedThreadID == "200:a:2:0")
        #expect(second.accept(threadID: "200:a:1:0", text: "とても長い長い文章がここに来る") == nil)
        #expect(second.accept(threadID: "200:a:2:0", text: "かずさ") == "かずさ")

        // 线程没了再出现，还认得
        second.remove(id: "200:a:2:0")
        #expect(second.pinnedThreadID == nil)
        second.register(HookThread(id: "200:a:2:0", hookcode: "HS@A", name: "BGI"))
        #expect(second.pinnedThreadID == "200:a:2:0")

        // 改回自动就忘掉
        #expect(second.pin(nil) == nil)
        #expect(second.remembered == nil)
    }

    @Test func normalizesHookCodes() {
        #expect(HookCode.normalize("  /HS-1C@44F7B0:WA2.exe \n") == "/HS-1C@44F7B0:WA2.exe")
        #expect(HookCode.normalize("HS-8@0:My Game.exe") == "HS-8@0:My Game.exe")
        #expect(HookCode.normalize("   ") == nil)
        #expect(HookCode.normalize("HS@1\nHS@2") == nil)
    }

    @Test func findsWineProcessByArgv0() {
        let exe = URL(fileURLWithPath: "/Users/me/Downloads/WHITE ALBUM2/WA2.exe")
        let candidates: [(pid_t, String)] = [
            (10, #"C:\windows\system32\explorer.exe"#),
            (11, #"Z:\Users\me\Other\WA2.exe"#),
            (12, #"Z:\Users\me\Downloads\WHITE ALBUM2\wa2.EXE"#),
        ]
        #expect(WineProcess.match(candidates, executable: exe) == [12])
        // 路径对不上（比如经过了符号链接）时按文件名找
        #expect(WineProcess.match(Array(candidates.prefix(2)), executable: exe) == [11])
        #expect(WineProcess.match(Array(candidates.prefix(1)), executable: exe).isEmpty)
    }

    @Test func windowsPath() {
        #expect(TextHookHost.windowsPath(URL(fileURLWithPath: "/Applications/Kazusa.app/Contents/Resources/texthook/x86"))
            == #"Z:\Applications\Kazusa.app\Contents\Resources\texthook\x86"#)
    }

    @Test func findsRepoHookFiles() {
        #expect(TextHookHost.files(for: .x86, bundle: nil) != nil)
        #expect(TextHookHost.files(for: .x64, bundle: nil) != nil)
    }

    @Test func readsNativeEngineText() async throws {
        let dir = FileManager.default.temporaryDirectory
        let (stream, continuation) = AsyncStream.makeStream(of: HookEvent.self)
        let source = try NativeTextSource(directory: dir) { continuation.yield($0) }
        let path = try #require(source.environment[NativeTextSource.environmentKey])
        #expect(FileManager.default.fileExists(atPath: path))

        // 和引擎一样非阻塞地打开；一行分两次写，验证按行拼接
        let fd = open(path, O_WRONLY | O_NONBLOCK)
        #expect(fd >= 0)
        let lines = #"{"type":"thread","id":"7:0:0:0","hookcode":"ONScripter","name":"ONScripter"}"# + "\n"
            + #"{"type":"text","id":"7:0:0:0","text":"「雪が"#
        let rest = #"降ってる」"}"# + "\n"
        _ = lines.withCString { write(fd, $0, strlen($0)) }
        try await Task.sleep(for: .milliseconds(50))
        _ = rest.withCString { write(fd, $0, strlen($0)) }
        close(fd)

        var events: [HookEvent] = []
        for await event in stream {
            events.append(event)
            if events.count == 2 { break }
        }
        #expect(events == [
            .thread(HookThread(id: "7:0:0:0", hookcode: "ONScripter", name: "ONScripter")),
            .text(threadID: "7:0:0:0", text: "「雪が降ってる」"),
        ])
        source.stop()
        source.stop()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
