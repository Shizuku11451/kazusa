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
        try await importRegistry(FontSubstitutes.registryFile(locale: locale, override: cjkFont), runtime: runtime, environment: initEnv)
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
    /// macOS 自带的一款中日文字体：文件名（字体链接按文件名查找）+ Wine 里的英文字体名。
    public struct MacFont: Hashable, Sendable {
        public var file: String
        public var face: String
    }

    /// ヒラギノ角ゴシック：日文字形。
    public static let hiraginoSans = MacFont(file: "ヒラギノ角ゴシック W3.ttc", face: "Hiragino Sans W3")
    /// 冬青黑体简体中文：简体字形，GBK 覆盖，也含假名。
    public static let hiraginoSansGB = MacFont(file: "Hiragino Sans GB.ttc", face: "Hiragino Sans GB W3")

    /// 按区域选默认字体，日文和中文的同一个汉字字形不同。
    public static func defaultFonts(for locale: GameLocale) -> [MacFont] {
        switch locale {
        case .japanese: [hiraginoSans, hiraginoSansGB]
        case .simplifiedChinese, .traditionalChinese: [hiraginoSansGB, hiraginoSans]
        }
    }

    /// 实际用于替换的字体名：用户填了就用用户的，留空（或旧版本的无效默认值）就按区域自动选。
    public static func targetFace(for locale: GameLocale, override: String) -> String {
        let trimmed = override.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == legacyDefault { return defaultFonts(for: locale)[0].face }
        return trimmed
    }

    /// 0.1 里写错的默认值（Wine 里的真名带 “W3”），读到时当作“自动”。
    static let legacyDefault = "Hiragino Sans GB"

    /// 游戏常用的 Windows 中日文字体，名字整体替换成 macOS 字体。
    public static let windowsFonts = [
        // 日文
        "MS Gothic", "ＭＳ ゴシック", "MS PGothic", "ＭＳ Ｐゴシック", "MS UI Gothic",
        "MS Mincho", "ＭＳ 明朝", "MS PMincho", "ＭＳ Ｐ明朝", "Meiryo", "メイリオ", "Meiryo UI",
        "Yu Gothic", "游ゴシック", "Yu Gothic UI", "Yu Mincho", "游明朝",
        // 简体中文
        "SimSun", "宋体", "NSimSun", "新宋体", "SimHei", "黑体", "Microsoft YaHei", "微软雅黑", "Microsoft YaHei UI",
        "KaiTi", "楷体", "FangSong", "仿宋",
        // 繁体中文
        "MingLiU", "細明體", "PMingLiU", "新細明體", "Microsoft JhengHei", "微軟正黑體", "Microsoft JhengHei UI",
    ]

    /// 西文界面字体：本身没有中日文字形，缺字时经“字体链接”回退。Wine 的菜单、对话框和不少游戏 UI 都用这些。
    public static let linkedUIFonts = [
        "Tahoma", "Tahoma Bold", "Microsoft Sans Serif", "MS Sans Serif", "MS Shell Dlg", "MS Shell Dlg 2",
        "Segoe UI", "Segoe UI Bold", "Arial", "Arial Bold", "Lucida Sans Unicode", "Verdana", "Courier New",
    ]

    public static func registryFile(locale: GameLocale, override: String = "") -> String {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let face = targetFace(for: locale, override: override)
        var lines = ["Windows Registry Editor Version 5.00", ""]
        for key in [
            #"HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\FontSubstitutes"#,
            #"HKEY_CURRENT_USER\Software\Wine\Fonts\Replacements"#,
        ] {
            lines.append("[\(key)]")
            for font in windowsFonts {
                lines.append("\"\(escape(font))\"=\"\(escape(face))\"")
            }
            lines.append("")
        }

        // 字体链接（REG_MULTI_SZ，每项 “文件名,字体名”）：覆盖 Wine 默认那些指向不存在的 Windows 字体文件的条目。
        let chain = defaultFonts(for: locale).map { "\($0.file),\($0.face)" }
        lines.append(#"[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\FontLink\SystemLink]"#)
        for font in linkedUIFonts + windowsFonts {
            lines.append("\"\(escape(font))\"=\(multiString(chain))")
        }
        lines.append("")
        return lines.joined(separator: "\r\n")
    }

    /// .reg 文件里 REG_MULTI_SZ 的写法：hex(7): 后跟 UTF-16LE 字节，每项以 0 结尾，末尾再加一个 0。
    static func multiString(_ items: [String]) -> String {
        var bytes: [UInt8] = []
        for item in items + [""] {
            for unit in item.utf16 + [0] {
                bytes.append(UInt8(unit & 0xFF))
                bytes.append(UInt8(unit >> 8))
            }
        }
        return "hex(7):" + bytes.map { String(format: "%02x", $0) }.joined(separator: ",")
    }
}
