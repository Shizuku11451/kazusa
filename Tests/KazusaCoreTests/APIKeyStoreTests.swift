// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation
import Testing
@testable import KazusaCore

@Suite struct APIKeyStoreTests {
    @Test func savesReadsAndRemovesKeysInPrivateFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = APIKeyStore(fileURL: dir.appendingPathComponent("apikeys.json"))
        let a = UUID(), b = UUID()

        store.setAPIKey("sk-a", for: a)
        store.setAPIKey("sk-b", for: b)
        #expect(store.apiKey(for: a) == "sk-a")
        #expect(store.apiKey(for: b) == "sk-b")

        let mode = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        store.setAPIKey("", for: a)
        #expect(try JSONFile.read([String: String].self, from: store.fileURL) == [b.uuidString: "sk-b"])
    }
}
