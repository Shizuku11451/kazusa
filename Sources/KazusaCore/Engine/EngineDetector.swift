// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation

public enum EngineKind: String, Codable, CaseIterable, Sendable {
    case kirikiri
    case nscripter
    case siglus
    case reallive
    case bgi
    case catSystem2
    case yuris
    case artemis
    case qlie
    case system4
    case unity
    case renpy
    case rpgMakerMV
    case tyrano
    case wolfRPG
    case unknown

    public var displayName: String {
        switch self {
        case .kirikiri: "KiriKiri（吉里吉里）"
        case .nscripter: "NScripter"
        case .siglus: "SiglusEngine"
        case .reallive: "RealLive"
        case .bgi: "BGI / Ethornell"
        case .catSystem2: "CatSystem2"
        case .yuris: "YU-RIS"
        case .artemis: "Artemis"
        case .qlie: "QLIE"
        case .system4: "AliceSoft System4"
        case .unity: "Unity"
        case .renpy: "Ren'Py"
        case .rpgMakerMV: "RPG Maker MV/MZ"
        case .tyrano: "TyranoScript"
        case .wolfRPG: "WOLF RPG"
        case .unknown: "未知引擎"
        }
    }
}

public struct EngineDetection: Sendable, Equatable {
    public var engine: EngineKind
    /// 0...1 的粗略置信度。
    public var confidence: Double
    /// 命中的特征，便于在界面上解释“为什么认为是这个引擎”。
    public var evidence: [String]
}

/// 通过目录里的特征文件识别 galgame 引擎。
///
/// 输入是相对路径列表（不读文件内容），所以既快又方便单测。
public enum EngineDetector {
    struct Rule: Sendable {
        let engine: EngineKind
        let weight: Double
        let description: String
        let matches: @Sendable (String) -> Bool
    }

    static func file(_ name: String) -> @Sendable (String) -> Bool {
        let target = name.lowercased()
        return { ($0 as NSString).lastPathComponent == target }
    }

    static func ext(_ e: String) -> @Sendable (String) -> Bool {
        let target = "." + e.lowercased()
        return { $0.hasSuffix(target) }
    }

    static func dir(_ name: String) -> @Sendable (String) -> Bool {
        let target = name.lowercased()
        return { path in path.split(separator: "/").dropLast().contains { $0 == target } }
    }

    static func pathSuffix(_ suffix: String) -> @Sendable (String) -> Bool {
        let target = suffix.lowercased()
        return { $0 == target || $0.hasSuffix("/" + target) }
    }

    static func namePrefix(_ prefix: String, ext e: String) -> @Sendable (String) -> Bool {
        let p = prefix.lowercased(), x = "." + e.lowercased()
        return { path in
            let name = (path as NSString).lastPathComponent
            return name.hasPrefix(p) && name.hasSuffix(x)
        }
    }

    static let rules: [Rule] = [
        Rule(engine: .kirikiri, weight: 0.9, description: "*.xp3 封包", matches: ext("xp3")),
        Rule(engine: .kirikiri, weight: 0.3, description: "krkr*.exe / tvpwin32", matches: { p in
            let n = (p as NSString).lastPathComponent
            return n.hasPrefix("krkr") || n.contains("tvpwin")
        }),

        Rule(engine: .nscripter, weight: 0.9, description: "nscript.dat", matches: file("nscript.dat")),
        Rule(engine: .nscripter, weight: 0.6, description: "*.nsa 封包", matches: ext("nsa")),
        Rule(engine: .nscripter, weight: 0.3, description: "0.txt / 00.txt 脚本", matches: { p in p == "0.txt" || p == "00.txt" }),

        Rule(engine: .siglus, weight: 0.9, description: "Scene.pck", matches: file("scene.pck")),
        Rule(engine: .siglus, weight: 0.5, description: "Gameexe.dat", matches: file("gameexe.dat")),
        Rule(engine: .siglus, weight: 0.5, description: "SiglusEngine.exe", matches: file("siglusengine.exe")),

        Rule(engine: .reallive, weight: 0.8, description: "Seen.txt", matches: file("seen.txt")),
        Rule(engine: .reallive, weight: 0.5, description: "Gameexe.ini", matches: file("gameexe.ini")),
        Rule(engine: .reallive, weight: 0.5, description: "RealLive.exe", matches: file("reallive.exe")),

        Rule(engine: .bgi, weight: 0.9, description: "BGI.exe", matches: file("bgi.exe")),
        Rule(engine: .bgi, weight: 0.6, description: "sysgrp.arc", matches: file("sysgrp.arc")),
        Rule(engine: .bgi, weight: 0.4, description: "BGI.gdb", matches: file("bgi.gdb")),

        Rule(engine: .catSystem2, weight: 0.7, description: "*.int 封包", matches: ext("int")),
        Rule(engine: .catSystem2, weight: 0.5, description: "cs2.exe / cs2conf", matches: { p in
            let n = (p as NSString).lastPathComponent
            return n == "cs2.exe" || n.hasPrefix("cs2conf")
        }),

        Rule(engine: .yuris, weight: 0.9, description: "*.ypf 封包", matches: ext("ypf")),
        Rule(engine: .yuris, weight: 0.6, description: "yst*.ybn 脚本", matches: namePrefix("yst", ext: "ybn")),

        Rule(engine: .artemis, weight: 0.9, description: "*.pfs 封包", matches: ext("pfs")),

        Rule(engine: .qlie, weight: 0.8, description: "GameData/*.pack", matches: { p in
            p.hasPrefix("gamedata/") && p.hasSuffix(".pack")
        }),

        Rule(engine: .system4, weight: 0.9, description: "*.ain 脚本", matches: ext("ain")),
        Rule(engine: .system4, weight: 0.4, description: "*.ald / *.afa 封包", matches: { p in p.hasSuffix(".ald") || p.hasSuffix(".afa") }),

        Rule(engine: .unity, weight: 0.9, description: "UnityPlayer.dll", matches: file("unityplayer.dll")),
        Rule(engine: .unity, weight: 0.6, description: "*_Data/globalgamemanagers", matches: { p in
            p.hasSuffix("/globalgamemanagers") && p.contains("_data/")
        }),

        Rule(engine: .renpy, weight: 0.9, description: "renpy/ 目录", matches: dir("renpy")),
        Rule(engine: .renpy, weight: 0.7, description: "*.rpa 封包", matches: ext("rpa")),

        Rule(engine: .rpgMakerMV, weight: 0.9, description: "rpg_core.js / rmmz_core.js", matches: { p in
            p.hasSuffix("js/rpg_core.js") || p.hasSuffix("js/rmmz_core.js")
        }),

        Rule(engine: .tyrano, weight: 0.9, description: "tyrano/ 目录", matches: dir("tyrano")),
        Rule(engine: .tyrano, weight: 0.4, description: "data/scenario/*.ks", matches: { p in
            p.contains("data/scenario/") && p.hasSuffix(".ks")
        }),

        Rule(engine: .wolfRPG, weight: 0.9, description: "Data.wolf", matches: file("data.wolf")),
        Rule(engine: .wolfRPG, weight: 0.5, description: "*.wolf 封包", matches: ext("wolf")),
    ]

    /// - Parameter relativePaths: 相对游戏根目录的路径，使用 "/" 分隔。大小写不敏感。
    public static func detect(relativePaths: [String]) -> EngineDetection {
        let normalized = relativePaths.map { $0.lowercased() }
        var scores: [EngineKind: Double] = [:]
        var evidence: [EngineKind: [String]] = [:]

        for rule in rules where normalized.contains(where: rule.matches) {
            // 多条规则命中时叠加，但上限为 1。
            scores[rule.engine, default: 0] = min(1, scores[rule.engine, default: 0] + rule.weight)
            evidence[rule.engine, default: []].append(rule.description)
        }

        guard let best = scores.max(by: { lhs, rhs in
            lhs.value == rhs.value ? lhs.key.rawValue > rhs.key.rawValue : lhs.value < rhs.value
        }) else {
            return EngineDetection(engine: .unknown, confidence: 0, evidence: [])
        }
        return EngineDetection(engine: best.key, confidence: best.value, evidence: evidence[best.key] ?? [])
    }

    /// 扫描目录（默认最多 3 层、2 万个条目），然后识别。
    public static func detect(directory: URL, maxDepth: Int = 3, maxEntries: Int = 20_000) -> EngineDetection {
        detect(relativePaths: DirectoryScanner.relativePaths(in: directory, maxDepth: maxDepth, maxEntries: maxEntries))
    }
}

public enum DirectoryScanner {
    public static func relativePaths(in directory: URL, maxDepth: Int, maxEntries: Int) -> [String] {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        let rootComponents = root.pathComponents.count
        var result: [String] = []
        for case let url as URL in enumerator {
            let components = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            let depth = components.count - rootComponents
            if depth > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            result.append(components.suffix(depth).joined(separator: "/"))
            if result.count >= maxEntries { break }
        }
        return result
    }
}
