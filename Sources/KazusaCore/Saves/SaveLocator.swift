// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation

/// 存档所在的一个位置：游戏目录里的某个文件夹 / 文件，或者 Wine 前缀 C 盘里的某个文件夹。
public struct SaveLocation: Codable, Hashable, Sendable, Comparable {
    public enum Root: String, Codable, Sendable {
        /// 相对游戏目录。
        case game
        /// 相对前缀的 drive_c（换了前缀也照样用新前缀里的同一位置）。
        case prefix
    }

    public var root: Root
    /// 用 “/” 分隔的相对路径。
    public var path: String

    public init(root: Root, path: String) {
        self.root = root
        self.path = path
    }

    public func url(gameDirectory: URL, driveC: URL?) -> URL? {
        switch root {
        case .game: gameDirectory.appendingPathComponent(path)
        case .prefix: driveC?.appendingPathComponent(path)
        }
    }

    public var displayName: String {
        switch root {
        case .game: "游戏目录/\(path)"
        case .prefix: "C:/\(path)"
        }
    }

    public static func < (a: Self, b: Self) -> Bool {
        (a.root.rawValue, a.path) < (b.root.rawValue, b.path)
    }
}

/// 找存档在哪：游戏退出后，看这次游玩期间游戏目录和前缀用户目录里哪些文件被改过。
/// 各家引擎、各个游戏存档位置五花八门，靠“改过什么”比按名字猜可靠。
public enum SaveLocator {
    /// 太大的文件多半是缓存或视频，不当存档。
    static let maxFileSize = 64 << 20
    /// 前缀里不算存档的目录：临时文件、Wine / 系统自己写的东西。
    static let ignoredPrefixComponents: Set<String> = ["temp", "tmp", "microsoft", "wine", "cache", "inetcache", "crashdumps"]

    /// - Parameters:
    ///   - driveC: Wine 游戏的前缀 C 盘；原生运行的游戏传 nil。
    ///   - since: 游戏启动的时间。
    public static func modifiedLocations(gameDirectory: URL, driveC: URL?, since: Date) -> Set<SaveLocation> {
        var result = Set<SaveLocation>()
        for path in modifiedFiles(in: gameDirectory, since: since) {
            let parts = path.split(separator: "/")
            // 根目录下的文件（ONScripter 的 save1.dat 等）记文件本身，子目录里的记第一层文件夹（savedata/ 等）。
            result.insert(SaveLocation(root: .game, path: String(parts[0])))
        }
        if let driveC {
            for top in ["users", "ProgramData"] {
                for path in modifiedFiles(in: driveC.appendingPathComponent(top), since: since) {
                    if let location = prefixLocation(top + "/" + path) { result.insert(location) }
                }
            }
        }
        return result
    }

    /// 把前缀里改过的文件归到“厂商 / 游戏”一级的文件夹：
    /// users/<用户>/AppData/Roaming/<厂商>、users/<用户>/Documents/<厂商>、ProgramData/<厂商>。
    static func prefixLocation(_ path: String) -> SaveLocation? {
        let parts = path.split(separator: "/").map(String.init)
        if parts.contains(where: { ignoredPrefixComponents.contains($0.lowercased()) }) { return nil }
        let depth: Int
        if parts.first == "ProgramData" {
            depth = 2
        } else if parts.count > 2, parts[2] == "AppData" {
            depth = 5 // users/u/AppData/Roaming/厂商
        } else if parts.count > 2, ["Documents", "My Documents", "Saved Games"].contains(parts[2]) {
            depth = 4 // users/u/Documents/厂商
        } else {
            return nil
        }
        // 文件直接放在 Roaming / Documents 下面（没有厂商文件夹）的不认，免得把整个目录当存档。
        guard parts.count > depth else { return nil }
        return SaveLocation(root: .prefix, path: parts.prefix(depth).joined(separator: "/"))
    }

    /// 目录里修改时间不早于 since 的文件（相对路径）。不跟随符号链接（Wine 把 Documents 等链到 macOS 的家目录）。
    static func modifiedFiles(in directory: URL, since: Date, maxEntries: Int = 100_000) -> [String] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        let base = directory.standardizedFileURL.path
        var result: [String] = []
        var seen = 0
        // 文件系统的时间精度可能只到秒。
        let threshold = since.addingTimeInterval(-2)
        for case let url as URL in enumerator {
            seen += 1
            if seen > maxEntries { break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let date = values.contentModificationDate, date >= threshold,
                  (values.fileSize ?? 0) <= maxFileSize else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            result.append(String(path.dropFirst(base.count + 1)))
        }
        return result
    }
}
