// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation

/// 一个游戏的翻译记录：每翻一句新的就往 JSON Lines 文件末尾追加一行。
/// 下次玩同一个游戏时，翻过的句子直接用记录里的译文，不再调用 LLM；最近的几百句恢复成历史。
/// 每行记着目标语言，换了目标语言只用对应语言的记录。
public struct TranslationStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public struct Record: Codable, Equatable, Sendable {
        public var source: String
        public var translation: String
        public var language: String

        enum CodingKeys: String, CodingKey {
            case source = "s", translation = "t", language = "l"
        }

        public init(source: String, translation: String, language: String) {
            self.source = source
            self.translation = translation
            self.language = language
        }
    }

    /// 按写入顺序读出某个目标语言的全部记录。读不出来的行（比如写到一半断电）跳过。
    public func load(language: String) -> [Record] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            guard let record = try? decoder.decode(Record.self, from: line), record.language == language else { return nil }
            return record
        }
    }

    public func append(_ record: Record) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(record)
        line.append(UInt8(ascii: "\n"))
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try line.write(to: fileURL)
            return
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
