// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation
import Testing
@testable import KazusaCore

@Suite struct VideoDecodingTests {
    let root = URL(fileURLWithPath: "/rt")

    func check(_ files: Set<String>) -> WineRuntime.VideoDecoding {
        WineRuntime.videoDecoding(root: root) { files.contains($0) }
    }

    @Test func bundledGStreamer() {
        #expect(check([
            "/rt/lib/wine/x86_64-unix/winegstreamer.so",
            "/rt/lib/GStreamer.framework/Libraries/libgstreamer-1.0.0.dylib",
        ]) == .available)
    }

    @Test func systemGStreamerFramework() {
        #expect(check([
            "/rt/lib/wine/x86_64-unix/winegstreamer.so",
            "/Library/Frameworks/GStreamer.framework/Libraries/libgstreamer-1.0.0.dylib",
        ]) == .available)
    }

    @Test func missingPieces() {
        #expect(check(["/rt/lib/GStreamer.framework/Libraries/libgstreamer-1.0.0.dylib"]) == .missingWinegstreamer)
        #expect(check(["/rt/lib/wine/x86_64-unix/winegstreamer.so"]) == .missingGStreamer)
    }

    @Test func rootResolvesFromBinary() {
        let runtime = WineRuntime(wineBinary: URL(fileURLWithPath: "/nonexistent-kazusa/wine-x/bin/wine"), source: .managed)
        #expect(runtime.rootDirectory.path == "/nonexistent-kazusa/wine-x")
    }

    /// 本机装了 Kazusa 托管的运行时时，确认真实目录结构能被识别。
    @Test func managedRuntimeOnThisMachine() throws {
        let runtimes = KazusaPaths.default.runtimesDir
        let entries = (try? FileManager.default.contentsOfDirectory(at: runtimes, includingPropertiesForKeys: nil)) ?? []
        for dir in entries where dir.lastPathComponent.hasPrefix("wine-staging") {
            let runtime = WineRuntime(wineBinary: dir.appendingPathComponent("bin/wine"), source: .managed)
            #expect(runtime.videoDecoding == .available, "\(dir.path)")
        }
    }
}
