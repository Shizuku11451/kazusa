// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation

/// 一个游戏的存档备份：每次备份是一个 zip，放在 Backups/<游戏 ID>/ 下。
/// zip 里是 game/… 和 prefix/… 两棵目录，外加记录位置的 manifest.json。
public struct SaveBackups: Sendable {
    public let directory: URL
    /// 自动备份（游戏退出后、恢复前）最多留几个；手动备份不自动删。
    public var keepAutomatic = 15
    /// 存档加起来超过这个大小就不备份（多半是把别的东西当成存档了）。
    public var maxTotalSize: Int64 = 512 << 20

    public init(directory: URL) {
        self.directory = directory
    }

    public enum Kind: String, Codable, Sendable {
        /// 游戏退出后自动备份。
        case automatic
        case manual
        /// 恢复备份前，先把当时的存档备份一份。
        case beforeRestore

        public var displayName: String {
            switch self {
            case .automatic: "自动"
            case .manual: "手动"
            case .beforeRestore: "恢复前"
            }
        }
    }

    public struct Backup: Identifiable, Hashable, Sendable {
        public var url: URL
        public var date: Date
        public var kind: Kind
        public var size: Int64
        public var id: URL { url }
    }

    struct Manifest: Codable {
        var version = 1
        var date: Date
        var kind: Kind
        var locations: [SaveLocation]
    }

    public enum BackupError: LocalizedError {
        case nothingToBackUp
        case tooLarge(Int64)
        case archiveFailed(String)
        case badArchive

        public var errorDescription: String? {
            switch self {
            case .nothingToBackUp: "还不知道这个游戏的存档在哪。玩一次、存个档再退出，Kazusa 会自动找到。"
            case .tooLarge(let size): "存档加起来有 \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))，太大了，没有备份。"
            case .archiveFailed(let log): "打包失败：\(log)"
            case .badArchive: "备份文件损坏或不是 Kazusa 的备份。"
            }
        }
    }

    // MARK: - 列出

    public func list() -> [Backup] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
        return files.compactMap { url -> Backup? in
            guard url.pathExtension == "zip", let (date, kind) = Self.parse(url.deletingPathExtension().lastPathComponent) else { return nil }
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            return Backup(url: url, date: date, kind: kind, size: size)
        }
        .sorted { $0.date > $1.date }
    }

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    static func fileName(date: Date, kind: Kind) -> String {
        "\(formatter.string(from: date))-\(kind.rawValue)"
    }

    static func parse(_ name: String) -> (Date, Kind)? {
        guard name.count > 16, let date = formatter.date(from: String(name.prefix(15))),
              let kind = Kind(rawValue: String(name.dropFirst(16))) else { return nil }
        return (date, kind)
    }

    // MARK: - 备份

    /// 把这些位置打包成一个备份。不存在的位置跳过；一个都不存在时报错。
    @discardableResult
    public func create(locations: [SaveLocation], gameDirectory: URL, driveC: URL?, kind: Kind, date: Date = Date()) async throws -> Backup {
        let fm = FileManager.default
        let existing = locations.sorted().compactMap { loc -> (SaveLocation, URL)? in
            guard let url = loc.url(gameDirectory: gameDirectory, driveC: driveC), fm.fileExists(atPath: url.path) else { return nil }
            return (loc, url)
        }
        guard !existing.isEmpty else { throw BackupError.nothingToBackUp }
        let total = existing.reduce(Int64(0)) { $0 + Self.size(of: $1.1) }
        guard total <= maxTotalSize else { throw BackupError.tooLarge(total) }

        let staging = fm.temporaryDirectory.appendingPathComponent("kazusa-backup-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        for (loc, url) in existing {
            let destination = staging.appendingPathComponent(loc.root.rawValue).appendingPathComponent(loc.path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: destination)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Manifest(date: date, kind: kind, locations: existing.map(\.0)))
            .write(to: staging.appendingPathComponent("manifest.json"))

        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var name = Self.fileName(date: date, kind: kind)
        // 同一秒里两次备份。
        var n = 1
        while fm.fileExists(atPath: directory.appendingPathComponent(name + ".zip").path) {
            n += 1
            name = Self.fileName(date: date.addingTimeInterval(TimeInterval(n - 1)), kind: kind)
        }
        let archive = directory.appendingPathComponent(name + ".zip")
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/ditto"),
                                                 arguments: ["-c", "-k", "--norsrc", staging.path, archive.path])
        guard result.exitCode == 0 else {
            try? fm.removeItem(at: archive)
            throw BackupError.archiveFailed(result.output)
        }
        prune()
        let size = Int64((try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        return Backup(url: archive, date: Self.parse(name)!.0, kind: kind, size: size)
    }

    /// 只留最近的 keepAutomatic 个自动备份。
    func prune() {
        let automatic = list().filter { $0.kind != .manual }
        for backup in automatic.dropFirst(keepAutomatic) {
            try? FileManager.default.removeItem(at: backup.url)
        }
    }

    // MARK: - 恢复

    /// 用备份里的内容替换现在的存档。调用前先用 `create(kind: .beforeRestore)` 备份当前存档。
    public func restore(_ backup: Backup, gameDirectory: URL, driveC: URL?) async throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("kazusa-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/ditto"),
                                                 arguments: ["-x", "-k", backup.url.path, staging.path])
        guard result.exitCode == 0 else { throw BackupError.archiveFailed(result.output) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: staging.appendingPathComponent("manifest.json")),
              let manifest = try? decoder.decode(Manifest.self, from: data) else { throw BackupError.badArchive }

        for loc in manifest.locations {
            // manifest 是自己写的，但还是防一下 “..” 跑到外面去。
            guard !loc.path.split(separator: "/").contains(".."), !loc.path.hasPrefix("/"),
                  let destination = loc.url(gameDirectory: gameDirectory, driveC: driveC) else { continue }
            let source = staging.appendingPathComponent(loc.root.rawValue).appendingPathComponent(loc.path)
            guard fm.fileExists(atPath: source.path) else { continue }
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: destination)
        }
    }

    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
            return Int64(values.fileSize ?? 0)
        }
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in e {
            total += Int64((try? file.resourceValues(forKeys: keys).fileSize) ?? 0)
        }
        return total
    }
}
