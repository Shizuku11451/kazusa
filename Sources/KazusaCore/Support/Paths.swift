// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation

/// 所有持久化数据的位置。默认在 ~/Library/Application Support/Kazusa 下。
public struct KazusaPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// 默认在 ~/Library/Application Support/Kazusa；设置环境变量 KAZUSA_HOME 可换到别处（开发、截图用）。
    public static let `default`: KazusaPaths = {
        if let home = ProcessInfo.processInfo.environment["KAZUSA_HOME"], !home.isEmpty {
            return KazusaPaths(root: URL(fileURLWithPath: home, isDirectory: true))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return KazusaPaths(root: base.appendingPathComponent("Kazusa", isDirectory: true))
    }()

    public var libraryFile: URL { root.appendingPathComponent("library.json") }
    public var settingsFile: URL { root.appendingPathComponent("settings.json") }
    public var prefixesDir: URL { root.appendingPathComponent("Prefixes", isDirectory: true) }
    public var runtimesDir: URL { root.appendingPathComponent("Runtimes", isDirectory: true) }
    public var logsDir: URL { root.appendingPathComponent("Logs", isDirectory: true) }

    public func ensureDirectories() throws {
        for dir in [root, prefixesDir, runtimesDir, logsDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

enum JSONFile {
    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
