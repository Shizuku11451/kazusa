// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation
import Testing
@testable import KazusaCore

@Suite struct RuntimeInstallerTests {
    @Test func verifyAcceptsMatchingChecksumOnly() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kazusa-sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        // SHA-256("abc")，大小写都认。
        let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        try RuntimeInstaller.verify(file, sha256: abc)
        try RuntimeInstaller.verify(file, sha256: abc.uppercased())
        #expect(throws: RuntimeInstaller.InstallError.self) {
            try RuntimeInstaller.verify(file, sha256: String(repeating: "0", count: 64))
        }
    }

    @Test func recommendedRuntimeIsPinned() {
        #expect(RuntimeInstaller.recommended.sha256.count == 64)
        #expect(RuntimeInstaller.recommended.url.lastPathComponent == "\(RuntimeInstaller.recommended.name).tar.xz")
    }
}
