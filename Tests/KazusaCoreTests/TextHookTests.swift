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

    @Test func windowsPath() {
        #expect(TextHookHost.windowsPath(URL(fileURLWithPath: "/Applications/Kazusa.app/Contents/Resources/texthook/x86"))
            == #"Z:\Applications\Kazusa.app\Contents\Resources\texthook\x86"#)
    }

    @Test func findsRepoHookFiles() {
        #expect(TextHookHost.files(for: .x86, bundle: nil) != nil)
        #expect(TextHookHost.files(for: .x64, bundle: nil) != nil)
    }
}
