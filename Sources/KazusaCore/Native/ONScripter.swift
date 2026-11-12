// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation

/// 游戏的运行方式：用 Wine 跑 Windows 程序，还是用原生重实现的引擎直接读游戏数据。
public enum GameBackend: String, Codable, CaseIterable, Sendable {
    case wine
    case native

    public var displayName: String {
        switch self {
        case .wine: "Wine"
        case .native: "原生引擎"
        }
    }
}

extension Game {
    /// 实际使用的运行方式。`backend` 为空（自动）时，引擎有可用的原生实现就用原生，否则用 Wine。
    public func resolvedBackend(nativeAvailable: Bool) -> GameBackend {
        if let backend { return backend }
        return NativeEngines.supports(engine) && nativeAvailable ? .native : .wine
    }
}

/// 打包进 Kazusa 的原生引擎：NScripter 用 ONScripter，KiriKiri 用 krkr2。
public enum NativeEngines {
    public static func supports(_ engine: EngineKind) -> Bool {
        engine == .nscripter || engine == .kirikiri
    }

    /// 原生引擎的名字，用于界面显示。
    public static func name(for engine: EngineKind) -> String? {
        switch engine {
        case .nscripter: "ONScripter"
        case .kirikiri: "krkr2"
        default: nil
        }
    }

    /// 原生引擎能不能直接把显示的台词交给翻译（打了 Kazusa 的补丁，见 `NativeTextSource`）。
    public static func providesText(_ engine: EngineKind) -> Bool {
        engine == .nscripter || engine == .kirikiri
    }

    /// 找打包的引擎程序；没打包（或 Intel Mac 上的 krkr2）返回 nil。
    public static func binary(for engine: EngineKind) -> URL? {
        switch engine {
        case .nscripter: ONScripter.binary()
        case .kirikiri: KiriKiri.binary()
        default: nil
        }
    }

    /// 读游戏目录，算出原生引擎的启动参数。
    public static func launchArguments(for game: Game) -> [String] {
        game.engine == .kirikiri ? KiriKiri.arguments(for: game) : ONScripter.launchArguments(for: game)
    }

    /// 这个游戏能不能用原生引擎跑，不能时给出原因（自动模式据此改用 Wine）。
    /// KiriKiri 游戏要看封包有没有加密；NScripter 游戏不用检查。
    public static func unsupportedReason(for game: Game) -> String? {
        game.engine == .kirikiri ? KiriKiri.readiness(of: game.directory).explanation : nil
    }
}

/// ONScripter（OnscripterYuri 分支）：NScripter 的开源重实现，直接读 0.txt / nscript.dat 和 .nsa 封包。
///
/// 二进制由 ThirdParty/onscripter-yuri/build.sh 构建，打包在 Kazusa.app/Contents/Resources/onscripter-yuri 里。
public enum ONScripter {
    public static let binaryName = "onsyuri"

    public static func searchRoots() -> [URL] {
        var roots: [URL] = []
        if let resources = Bundle.main.resourceURL {
            roots.append(resources.appendingPathComponent("onscripter-yuri", isDirectory: true))
        }
        // 开发时（swift run）没有 .app 包，直接用仓库里构建好的文件。
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Native
            .deletingLastPathComponent() // KazusaCore
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent()
        roots.append(repo.appendingPathComponent("ThirdParty/onscripter-yuri/prebuilt", isDirectory: true))
        return roots
    }

    public static func binary(searchRoots: [URL] = searchRoots()) -> URL? {
        searchRoots
            .map { $0.appendingPathComponent(binaryName) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// 脚本编码，对应 onsyuri 的 `--enc:` 参数。
    public enum ScriptEncoding: String, Sendable {
        case gbk, sjis, utf8
    }

    /// 按 ONScripter 自己的查找顺序找脚本，返回读出来（已解密）的开头一段。
    /// nscr_sec.dat / nscript.___ 用了别的加密方式，读不了时返回 nil，由区域决定编码。
    static func scriptSample(in directory: URL, limit: Int = 256 * 1024) -> Data? {
        let candidates: [(String, UInt8?)] = [("0.txt", nil), ("00.txt", nil), ("nscript.dat", 0x84)]
        for (name, key) in candidates {
            let url = directory.appendingPathComponent(name)
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            guard var data = try? handle.read(upToCount: limit) else { continue }
            if let key { data = Data(data.map { $0 ^ key }) }
            return data
        }
        return nil
    }

    /// 判断脚本编码：有非 ASCII 字符且整段是合法 UTF-8 的是 UTF-8 脚本（新的汉化 / 移植常用），
    /// 否则按区域在 Shift-JIS 和 GBK 之间选。onsyuri 不支持 Big5，繁体中文只能按 GBK 读。
    public static func detectEncoding(sample: Data?, locale: GameLocale) -> ScriptEncoding {
        if let sample, sample.contains(where: { $0 >= 0x80 }), isUTF8(sample) { return .utf8 }
        return locale == .japanese ? .sjis : .gbk
    }

    /// 截断的样本末尾可能断在一个多字节字符中间，最多容忍末尾 3 个字节。
    static func isUTF8(_ data: Data) -> Bool {
        (0...min(3, data.count)).contains { String(data: data.dropLast($0), encoding: .utf8) != nil }
    }

    /// 字体：游戏目录里自带 default.ttf 就让 ONScripter 自己用，否则按区域用 macOS 自带的冬青黑体 / ヒラギノ角ゴ。
    public static func font(for game: Game, fontsDirectory: URL = URL(fileURLWithPath: "/System/Library/Fonts")) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: game.directory.appendingPathComponent("default.ttf").path) { return nil }
        return FontSubstitutes.defaultFonts(for: game.locale)
            .map { fontsDirectory.appendingPathComponent($0.file) }
            .first { fm.fileExists(atPath: $0.path) }
    }

    /// onsyuri 的命令行参数。存档留在游戏目录（ONScripter 的默认位置），和 Windows 版互通。
    public static func arguments(for game: Game, encoding: ScriptEncoding, font: URL?) -> [String] {
        var args = ["--root", game.directory.path, "--enc:\(encoding.rawValue)"]
        if let font { args += ["--font", font.path] }
        return args + game.arguments
    }

    /// 读游戏目录，算出完整的启动参数。
    public static func launchArguments(for game: Game) -> [String] {
        let encoding = detectEncoding(sample: scriptSample(in: game.directory), locale: game.locale)
        return arguments(for: game, encoding: encoding, font: font(for: game))
    }
}
