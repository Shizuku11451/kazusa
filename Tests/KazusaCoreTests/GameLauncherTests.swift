// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation
import Testing
@testable import KazusaCore

@Suite struct GameLauncherTests {
    /// 原生引擎崩溃后会在 onExit 里立刻改用 Wine 重新启动，这时会话必须已经清掉。
    @Test func sessionIsClearedBeforeOnExit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kazusa-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = GameLauncher(paths: KazusaPaths(root: root))
        let game = Game(title: "t", directory: root, executable: "", engine: .unknown, locale: .japanese)

        let stillRunning: Bool = try await withCheckedThrowingContinuation { continuation in
            Task {
                do {
                    try await launcher.launchNative(game, binary: URL(fileURLWithPath: "/usr/bin/false"), arguments: []) { _ in
                        Task { continuation.resume(returning: await launcher.isRunning(game.id)) }
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        #expect(!stillRunning)
    }
}
