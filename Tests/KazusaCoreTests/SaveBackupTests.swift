// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation
import Testing
@testable import KazusaCore

@Suite struct SaveBackupTests {
    func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kazusa-saves-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func write(_ text: String, _ url: URL, modified: Date? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
    }

    @Test func prefixLocationsCollapseToVendorFolder() {
        #expect(SaveLocator.prefixLocation("users/me/AppData/Roaming/Leaf/WA2/save01.dat")
                == SaveLocation(root: .prefix, path: "users/me/AppData/Roaming/Leaf"))
        #expect(SaveLocator.prefixLocation("users/me/Documents/AliceSoft/Rance/sav.asd")
                == SaveLocation(root: .prefix, path: "users/me/Documents/AliceSoft"))
        #expect(SaveLocator.prefixLocation("ProgramData/Key/save.dat") == SaveLocation(root: .prefix, path: "ProgramData/Key"))
        #expect(SaveLocator.prefixLocation("users/me/AppData/Local/Temp/x/y.tmp") == nil)
        #expect(SaveLocator.prefixLocation("users/me/AppData/Roaming/Microsoft/Windows/x") == nil)
        #expect(SaveLocator.prefixLocation("users/me/AppData/Roaming/loose.ini") == nil)
        #expect(SaveLocator.prefixLocation("users/me/Desktop/a.txt") == nil)
    }

    @Test func findsOnlyFilesModifiedDuringSession() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let game = root.appendingPathComponent("game")
        let driveC = root.appendingPathComponent("drive_c")
        let old = Date().addingTimeInterval(-3600)
        try write("x", game.appendingPathComponent("data.xp3"), modified: old)
        try write("x", game.appendingPathComponent("savedata/data0.kdt"))
        try write("x", game.appendingPathComponent("save1.dat"))
        try write("x", driveC.appendingPathComponent("users/me/AppData/Roaming/Leaf/WA2/s.dat"))
        try write("x", driveC.appendingPathComponent("users/me/AppData/Roaming/Old/s.dat"), modified: old)

        let found = SaveLocator.modifiedLocations(gameDirectory: game, driveC: driveC, since: Date().addingTimeInterval(-60))
        #expect(found == [
            SaveLocation(root: .game, path: "savedata"),
            SaveLocation(root: .game, path: "save1.dat"),
            SaveLocation(root: .prefix, path: "users/me/AppData/Roaming/Leaf"),
        ])
    }

    @Test func backupAndRestoreRoundTrip() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let game = root.appendingPathComponent("game")
        let driveC = root.appendingPathComponent("drive_c")
        let locations = [SaveLocation(root: .game, path: "savedata"), SaveLocation(root: .game, path: "save1.dat"),
                         SaveLocation(root: .prefix, path: "users/me/AppData/Roaming/Leaf")]
        try write("A", game.appendingPathComponent("savedata/data0.kdt"))
        try write("B", game.appendingPathComponent("save1.dat"))
        try write("C", driveC.appendingPathComponent("users/me/AppData/Roaming/Leaf/WA2/s.dat"))

        var backups = SaveBackups(directory: root.appendingPathComponent("backups"))
        backups.keepAutomatic = 2
        let backup = try await backups.create(locations: locations, gameDirectory: game, driveC: driveC, kind: .manual)
        #expect(backups.list().map(\.kind) == [.manual])

        // 玩坏了：改了一个、多了一个文件。
        try write("A2", game.appendingPathComponent("savedata/data0.kdt"))
        try write("new", game.appendingPathComponent("savedata/data1.kdt"))
        try FileManager.default.removeItem(at: driveC.appendingPathComponent("users"))

        try await backups.restore(backup, gameDirectory: game, driveC: driveC)
        #expect(try String(contentsOf: game.appendingPathComponent("savedata/data0.kdt"), encoding: .utf8) == "A")
        #expect(!FileManager.default.fileExists(atPath: game.appendingPathComponent("savedata/data1.kdt").path))
        #expect(try String(contentsOf: driveC.appendingPathComponent("users/me/AppData/Roaming/Leaf/WA2/s.dat"), encoding: .utf8) == "C")

        // 自动备份只留最近两个，手动的不删。
        let base = Date()
        for n in 0..<4 {
            try await backups.create(locations: locations, gameDirectory: game, driveC: driveC, kind: .automatic,
                                     date: base.addingTimeInterval(TimeInterval(n * 10)))
        }
        #expect(backups.list().filter { $0.kind == .automatic }.count == 2)
        #expect(backups.list().contains { $0.kind == .manual })
    }

    @Test func nothingToBackUp() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let backups = SaveBackups(directory: root.appendingPathComponent("backups"))
        await #expect(throws: SaveBackups.BackupError.self) {
            try await backups.create(locations: [SaveLocation(root: .game, path: "nope")], gameDirectory: root, driveC: nil, kind: .manual)
        }
    }

    @Test func exclusivePrefixClonesTemplate() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = KazusaPaths(root: root)
        let template = WinePrefix(name: "default-ja", paths: paths)
        for f in ["system.reg", "drive_c/windows/system32/kernel32.dll", "drive_c/windows/syswow64/kernel32.dll"] {
            try write("x", template.url.appendingPathComponent(f))
        }
        var game = Game(title: "t", directory: root, executable: "a.exe", engine: .unknown, locale: .japanese)
        #expect(!game.usesExclusivePrefix)
        game.usesExclusivePrefix = true
        #expect(game.prefixName.hasPrefix("game-"))
        let prefix = WinePrefix(name: game.prefixName, paths: paths)
        #expect(try prefix.cloneIfMissing(from: template))
        #expect(prefix.isInitialized)
        #expect(try !prefix.cloneIfMissing(from: template)) // 已经有了就不再复制
        game.usesExclusivePrefix = false
        #expect(game.prefixName == "default-ja")
    }
}
