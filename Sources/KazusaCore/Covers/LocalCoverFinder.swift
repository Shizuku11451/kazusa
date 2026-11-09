// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation

/// 在游戏目录里找现成的封面图（有些汉化包、DL 版会附带 cover.jpg、package.png 之类）。
public enum LocalCoverFinder {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "bmp"]

    /// 文件名（不含扩展名，小写）里出现这些词就算候选，越靠前分越高。
    static let keywords: [(String, Int)] = [
        ("cover", 100), ("封面", 100), ("jacket", 90), ("package", 80), ("pkg", 70),
        ("パッケージ", 80), ("ジャケット", 90), ("box", 60), ("folder", 50), ("poster", 50),
    ]

    /// 给相对路径打分，nil 表示不是候选。
    static func score(relativePath: String) -> Int? {
        let url = URL(fileURLWithPath: relativePath)
        guard imageExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        guard let best = keywords.filter({ stem.contains($0.0) }).map(\.1).max() else { return nil }
        // 浅层的文件更可能是封面；完全等于关键词（cover.jpg）再加分。
        let depth = relativePath.split(separator: "/").count - 1
        let exact = keywords.contains { $0.0 == stem } ? 20 : 0
        return best + exact - depth * 10
    }

    public static func bestCandidate(relativePaths: [String]) -> String? {
        ranked(relativePaths).first
    }

    /// 候选按分数从高到低排；同分时按路径排，保证结果稳定。
    static func ranked(_ relativePaths: [String]) -> [String] {
        var scored: [(path: String, score: Int)] = []
        for path in relativePaths {
            if let s = score(relativePath: path) { scored.append((path, s)) }
        }
        scored.sort { a, b in a.score != b.score ? a.score > b.score : a.path < b.path }
        return scored.map(\.path)
    }

    /// 返回找到的封面图数据。小于 20 KB 的多半是按钮、图标之类，跳过。
    public static func find(in directory: URL) -> Data? {
        let paths = DirectoryScanner.relativePaths(in: directory, maxDepth: 2, maxEntries: 20_000)
        for path in ranked(paths).prefix(5) {
            let url = directory.appendingPathComponent(path)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size >= 20_000, size <= 30_000_000,
                  let data = try? Data(contentsOf: url), CoverStore.isImage(data)
            else { continue }
            return data
        }
        return nil
    }
}
