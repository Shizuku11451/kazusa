// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation

/// 游戏库：一个 JSON 文件。
public struct LibraryStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    struct Document: Codable {
        var version: Int
        var games: [Game]
    }

    public func load() throws -> [Game] {
        try JSONFile.read(Document.self, from: fileURL)?.games ?? []
    }

    public func save(_ games: [Game]) throws {
        try JSONFile.write(Document(version: 1, games: games), to: fileURL)
    }
}
