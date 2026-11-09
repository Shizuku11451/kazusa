// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation

/// 换上打过补丁的 `wow64cpu.dll`，绕开新版 Rosetta 2 的远跳转问题。
///
/// 在较新的 macOS 上，Rosetta 处理 32↔64 位之间的 `ljmp` 时偶尔不切换 CPU 模式，
/// Wine 的 WoW64 每次系统调用都要切换，于是 32 位游戏会随机崩溃或卡死。
/// 补丁把远跳转换成远返回，详见 `ThirdParty/wow64cpu-rosetta/README.md`。
///
/// DLL 和 Wine 版本绑定，只在找到对应版本的预编译文件时才替换；
/// 只改 Kazusa 托管的运行时和游戏前缀，不动系统里的 Wine。
public enum RosettaWoW64Fix {
    public enum Outcome: Equatable, Sendable {
        /// 不是 Apple Silicon，或运行时不是 Kazusa 托管的。
        case notApplicable
        /// 没有这个 Wine 版本的修复 DLL。
        case unavailable(version: String?)
        /// 已经是修复版（或刚刚换上）。
        case applied(version: String, changed: Bool)
    }

    static let dllName = "wow64cpu.dll"

    /// 从 `wine --version` 的输出（如 `wine-11.21 (Staging)`）里取版本号。
    public static func wineVersion(fromVersionOutput output: String) -> String? {
        guard let range = output.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression) else { return nil }
        return String(output[range])
    }

    /// 查找修复 DLL 的目录，靠前的优先。每个目录下的布局是 `wine-<版本>/wow64cpu.dll`。
    public static func searchRoots(paths: KazusaPaths) -> [URL] {
        var roots = [paths.fixesDir.appendingPathComponent("wow64cpu", isDirectory: true)]
        if let resources = Bundle.main.resourceURL {
            roots.append(resources.appendingPathComponent("wow64cpu-rosetta/prebuilt", isDirectory: true))
        }
        // 开发时（swift run）没有 .app 包，直接用仓库里的文件。
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Wine
            .deletingLastPathComponent() // KazusaCore
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent()
        roots.append(repo.appendingPathComponent("ThirdParty/wow64cpu-rosetta/prebuilt", isDirectory: true))
        return roots
    }

    public static func patchedDLL(version: String, searchRoots: [URL]) -> URL? {
        searchRoots
            .map { $0.appendingPathComponent("wine-\(version)/\(dllName)") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 运行时里的 64 位 `wow64cpu.dll`。
    static func runtimeDLL(_ runtime: WineRuntime) -> URL {
        runtime.binDirectory.deletingLastPathComponent()
            .appendingPathComponent("lib/wine/x86_64-windows/\(dllName)")
    }

    static func prefixDLL(_ prefix: URL) -> URL {
        prefix.appendingPathComponent("drive_c/windows/system32/\(dllName)")
    }

    /// 找到对应版本的修复 DLL。不需要或没有时返回 nil 和原因。
    public static func resolve(runtime: WineRuntime, paths: KazusaPaths) async -> (dll: URL?, version: String?, outcome: Outcome?) {
        guard SystemCheck.isAppleSilicon, runtime.source == .managed else { return (nil, nil, .notApplicable) }
        guard let output = await runtime.version(), let version = wineVersion(fromVersionOutput: output) else {
            return (nil, nil, .unavailable(version: nil))
        }
        guard let dll = patchedDLL(version: version, searchRoots: searchRoots(paths: paths)) else {
            return (nil, version, .unavailable(version: version))
        }
        return (dll, version, nil)
    }

    /// 在创建 / 更新前缀**之前**调用：修好运行时里的那份，wineboot 复制进前缀的就是修复版。
    public static func applyToRuntime(_ runtime: WineRuntime, paths: KazusaPaths) async throws -> Outcome {
        let (dll, version, outcome) = await resolve(runtime: runtime, paths: paths)
        if let outcome { return outcome }
        let changed = try install(dll!, over: runtimeDLL(runtime))
        return .applied(version: version!, changed: changed)
    }

    /// 在前缀准备好**之后**调用：前缀是用旧运行时建的，或 wineboot 覆盖过时，补上前缀里的那份。
    public static func applyToPrefix(_ prefix: URL, runtime: WineRuntime, paths: KazusaPaths) async throws -> Outcome {
        let (dll, version, outcome) = await resolve(runtime: runtime, paths: paths)
        if let outcome { return outcome }
        let target = prefixDLL(prefix)
        guard FileManager.default.fileExists(atPath: target.path) else { return .applied(version: version!, changed: false) }
        let changed = try install(dll!, over: target)
        return .applied(version: version!, changed: changed)
    }

    /// 用 `source` 替换 `target`。内容相同时什么也不做；第一次替换时把原文件备份成 `.orig`。
    /// - Returns: 是否真的改了文件。
    @discardableResult
    static func install(_ source: URL, over target: URL) throws -> Bool {
        let fm = FileManager.default
        let new = try Data(contentsOf: source)
        if let old = try? Data(contentsOf: target), old == new { return false }

        let backup = target.appendingPathExtension("orig")
        if fm.fileExists(atPath: target.path), !fm.fileExists(atPath: backup.path) {
            try fm.copyItem(at: target, to: backup)
        }
        try new.write(to: target, options: .atomic)
        return true
    }
}
