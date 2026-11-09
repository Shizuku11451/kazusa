// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation

/// 构建传给 Wine 的环境变量。
public enum WineEnvironment {
    /// 禁止 Wine 往 macOS 里写“开始菜单”快捷方式和文件关联。
    static let baseDllOverrides = "winemenubuilder.exe=d"

    public static func make(
        runtime: WineRuntime,
        prefix: URL,
        locale: GameLocale,
        extra: [String: String] = [:],
        inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "SHELL"] {
            if let value = inherited[key] { env[key] = value }
        }
        env["PATH"] = [runtime.binDirectory.path, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        env["WINEPREFIX"] = prefix.path
        // 转区的核心：LANG/LC_ALL 决定 Wine 内的 ANSI 代码页（936 / 950 / 932）。
        env["LANG"] = locale.posixLocale
        env["LC_ALL"] = locale.posixLocale
        env["WINEDEBUG"] = "-all"
        env["WINEDLLOVERRIDES"] = baseDllOverrides

        for (key, value) in extra {
            if key == "WINEDLLOVERRIDES" {
                env[key] = baseDllOverrides + ";" + value
            } else {
                env[key] = value
            }
        }
        return env
    }
}

/// 一个 Wine 前缀（相当于一台独立的“Windows C 盘”）。
public struct WinePrefix: Sendable {
    public let name: String
    public let url: URL

    public init(name: String, paths: KazusaPaths) {
        self.name = name
        self.url = paths.prefixesDir.appendingPathComponent(name, isDirectory: true)
    }

    public var isInitialized: Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("system.reg").path)
    }

    public var driveC: URL { url.appendingPathComponent("drive_c", isDirectory: true) }

    /// 初始化前缀并写入中日文字体映射。已初始化时只刷新字体映射。
    public func prepare(runtime: WineRuntime, locale: GameLocale, cjkFont: String) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var initEnv = WineEnvironment.make(runtime: runtime, prefix: url, locale: locale)
        // 初始化时跳过 Mono / Gecko 安装弹窗，galgame 基本用不到。
        initEnv["WINEDLLOVERRIDES"] = "mscoree,mshtml=;" + WineEnvironment.baseDllOverrides

        if !isInitialized {
            let result = try await ProcessRunner.run(runtime.wineBinary, arguments: ["wineboot", "--init"], environment: initEnv)
            _ = try await ProcessRunner.run(runtime.wineserver, arguments: ["-w"], environment: initEnv)
            guard isInitialized else {
                throw PrefixError.initFailed(result.output.suffix(2000).description)
            }
        }
        try await importRegistry(FontSubstitutes.registryFile(targetFont: cjkFont), runtime: runtime, environment: initEnv)
    }

    func importRegistry(_ content: String, runtime: WineRuntime, environment: [String: String]) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kazusa-\(UUID().uuidString).reg")
        // regedit 需要 UTF-16LE + BOM 才能正确读入中日文键值。
        var data = Data([0xFF, 0xFE])
        data.append(content.data(using: .utf16LittleEndian)!)
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let result = try await ProcessRunner.run(runtime.wineBinary, arguments: ["regedit", "/S", file.path], environment: environment)
        _ = try await ProcessRunner.run(runtime.wineserver, arguments: ["-w"], environment: environment)
        if result.exitCode != 0 {
            throw PrefixError.registryFailed(result.output)
        }
    }

    public enum PrefixError: LocalizedError {
        case initFailed(String)
        case registryFailed(String)

        public var errorDescription: String? {
            switch self {
            case .initFailed(let log): "Wine 前缀初始化失败：\(log)"
            case .registryFailed(let log): "写入注册表失败：\(log)"
            }
        }
    }
}

/// 把游戏常用的 Windows 中日文字体映射到 macOS 自带字体，解决方块字 / 缺字。
public enum FontSubstitutes {
    public static let windowsFonts = [
        // 日文
        "MS Gothic", "ＭＳ ゴシック", "MS PGothic", "ＭＳ Ｐゴシック", "MS UI Gothic",
        "MS Mincho", "ＭＳ 明朝", "MS PMincho", "ＭＳ Ｐ明朝", "Meiryo", "メイリオ", "Yu Gothic", "游ゴシック",
        // 简体中文
        "SimSun", "宋体", "NSimSun", "新宋体", "SimHei", "黑体", "Microsoft YaHei", "微软雅黑", "KaiTi", "楷体",
        // 繁体中文
        "MingLiU", "細明體", "PMingLiU", "新細明體", "Microsoft JhengHei", "微軟正黑體",
    ]

    /// macOS 自带、同时覆盖中文和假名的字体。
    public static let defaultTargetFont = "Hiragino Sans GB"

    public static func registryFile(targetFont: String) -> String {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        var lines = ["Windows Registry Editor Version 5.00", ""]
        for key in [
            #"HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\FontSubstitutes"#,
            #"HKEY_CURRENT_USER\Software\Wine\Fonts\Replacements"#,
        ] {
            lines.append("[\(key)]")
            for font in windowsFonts {
                lines.append("\"\(escape(font))\"=\"\(escape(targetFont))\"")
            }
            lines.append("")
        }
        return lines.joined(separator: "\r\n")
    }
}
