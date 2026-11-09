// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation

/// 导入游戏时的分析结果：猜测主程序、引擎、区域和标题。
public struct GameInspection: Sendable {
    public var title: String
    public var engine: EngineDetection
    public var executableCandidates: [String]
    public var suggestedLocale: GameLocale

    public var suggestedExecutable: String? { executableCandidates.first }
}

public enum GameInspector {
    /// 名字里带这些词的 exe 通常不是游戏本体。
    static let chineseExecutableMarkers = ["chs", "_cn", "-cn", "汉化", "中文", "简体", "zh"]

    static let nonGameExecutableKeywords = [
        "config", "setup", "install", "uninst", "unins", "update", "patch",
        "setting", "launcher_config", "vcredist", "dxsetup", "directx", "crash",
        "unitycrashhandler", "notification_helper", "設定", "设定", "环境", "環境",
    ]

    /// 名字里带这些词时，大概率是汉化版。
    static let chineseMarkers = ["汉化", "漢化", "中文", "简体", "簡體", "繁體", "繁体", "chs", "cht", "_cn", "-cn", "(cn)", "[cn]"]

    public static func inspect(directory: URL) -> GameInspection {
        let paths = DirectoryScanner.relativePaths(in: directory, maxDepth: 3, maxEntries: 20_000)
        let engine = EngineDetector.detect(relativePaths: paths)
        let title = directory.lastPathComponent
        let candidates = rankExecutables(paths: paths, directoryName: title, directory: directory)
        let locale = guessLocale(title: title, paths: paths)
        return GameInspection(title: title, engine: engine, executableCandidates: candidates, suggestedLocale: locale)
    }

    /// 给 exe 打分排序：目录浅、文件大、名字像游戏本体的排前面。
    public static func rankExecutables(paths: [String], directoryName: String, directory: URL? = nil) -> [String] {
        let exes = paths.filter { $0.lowercased().hasSuffix(".exe") }
        let dirName = directoryName.lowercased()
        // 汉化发布常用文件名写说明，例如「BGI_patch.exe 启动游戏 汉化移植v1.01版本.txt」。
        let hintNames = paths
            .filter { !$0.lowercased().hasSuffix(".exe") && !$0.contains("/") }
            .map { $0.lowercased() }

        func score(_ path: String) -> Double {
            let lower = path.lowercased()
            let name = ((lower as NSString).lastPathComponent as NSString).deletingPathExtension
            var s = 0.0
            s -= Double(path.split(separator: "/").count - 1) * 2
            if nonGameExecutableKeywords.contains(where: { lower.contains($0) }) { s -= 10 }
            if !name.isEmpty, dirName.contains(name) || name.contains(dirName) { s += 3 }
            if ["game", "start", "play", "siglusengine", "bgi", "reallive"].contains(name) { s += 2 }
            // 汉化程序：BGI-CHS.exe、xxx_cn.exe、xxx汉化.exe……
            if chineseExecutableMarkers.contains(where: { name.contains($0) }) { s += 2 }
            // 被说明文件点名的程序，比其他规则都可靠。
            let fileName = (lower as NSString).lastPathComponent
            if hintNames.contains(where: { $0.contains(fileName) }) { s += 20 }
            if let directory,
               let size = try? directory.appendingPathComponent(path).resourceValues(forKeys: [.fileSizeKey]).fileSize {
                // 主程序往往比工具程序大，按 MB 的对数加一点分。
                s += log2(Double(max(size, 1)) / 1_048_576 + 1)
            }
            return s
        }

        let scored: [(path: String, score: Double)] = exes.map { ($0, score($0)) }
        let sorted = scored.sorted { lhs, rhs in
            lhs.score == rhs.score ? lhs.path < rhs.path : lhs.score > rhs.score
        }
        return sorted.map { $0.path }
    }

    /// 汉化版优先：只要标题或文件名里有汉化标记就用简体中文；
    /// 文件名里出现假名才判定为日文原版；都没有时默认简体中文（本项目的主要场景）。
    public static func guessLocale(title: String, paths: [String]) -> GameLocale {
        let haystack = ([title] + paths.prefix(500)).map { $0.lowercased() }
        if haystack.contains(where: { s in chineseMarkers.contains(where: { s.contains($0) }) }) {
            if haystack.contains(where: { $0.contains("繁") || $0.contains("cht") }) {
                return .traditionalChinese
            }
            return .simplifiedChinese
        }
        if haystack.contains(where: containsKana) {
            return .japanese
        }
        return .simplifiedChinese
    }

    static func containsKana(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
    }
}
