// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation

/// 一个可用的 Wine 运行时（x86_64 构建，经 Rosetta 2 运行）。
///
/// Kazusa 不自带 Windows 兼容层（那就是 Wine 本身），但运行时的发现、安装、前缀配置、
/// 启动参数都由我们自己管理，不依赖 CrossOver / Whisky 等现有前端。
public struct WineRuntime: Codable, Hashable, Sendable, Identifiable {
    public var id: String { wineBinary.path }
    /// `wine`（Wine 9+ 的统一加载器，WoW64 模式可跑 32 位程序）或老版本的 `wine64`。
    public var wineBinary: URL
    public var source: Source

    public enum Source: String, Codable, Sendable {
        /// 安装在 Kazusa 自己的 Runtimes 目录里。
        case managed
        /// 系统上已有的（/Applications、Homebrew 等）。
        case system
        /// 用户手动指定的路径。
        case custom
    }

    public init(wineBinary: URL, source: Source) {
        self.wineBinary = wineBinary
        self.source = source
    }

    public var binDirectory: URL { wineBinary.deletingLastPathComponent() }

    public var wineserver: URL { binDirectory.appendingPathComponent("wineserver") }

    public var displayName: String {
        switch source {
        case .managed: "内置：\(binDirectory.deletingLastPathComponent().lastPathComponent)"
        case .system: "系统：\(wineBinary.path)"
        case .custom: "自定义：\(wineBinary.path)"
        }
    }

    /// 运行时的安装根目录（bin 的上一级）。Homebrew 的 wine 是符号链接，先解析到真实位置。
    public var rootDirectory: URL {
        wineBinary.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// 能不能解码游戏里的视频（OP/ED）。Wine 的 DirectShow / Media Foundation 都交给
    /// winegstreamer 处理，它又要加载 GStreamer；两者缺一，视频就是黑屏或者卡住。
    public var videoDecoding: VideoDecoding {
        Self.videoDecoding(root: rootDirectory) { FileManager.default.fileExists(atPath: $0) }
    }

    public enum VideoDecoding: Equatable, Sendable {
        case available
        /// 这个 Wine 构建没带 winegstreamer。
        case missingWinegstreamer
        /// 有 winegstreamer，但运行时里和 /Library/Frameworks 下都没有 GStreamer。
        case missingGStreamer

        public var summary: String {
            switch self {
            case .available: "可用"
            case .missingWinegstreamer: "不可用：这个 Wine 构建没有 winegstreamer"
            case .missingGStreamer: "不可用：找不到 GStreamer（可以改用 Gcenx 的 wine-staging 构建，它自带 GStreamer）"
            }
        }
    }

    /// winegstreamer.so 的 rpath 依次查找运行时自带的 GStreamer.framework 和系统级的
    /// /Library/Frameworks/GStreamer.framework。
    static func videoDecoding(root: URL, fileExists: (String) -> Bool) -> VideoDecoding {
        let lib = root.appendingPathComponent("lib")
        let unixDirs = ["wine/x86_64-unix", "wine"]
        guard unixDirs.contains(where: { fileExists(lib.appendingPathComponent("\($0)/winegstreamer.so").path) }) else {
            return .missingWinegstreamer
        }
        let gstreamer = "GStreamer.framework/Libraries/libgstreamer-1.0.0.dylib"
        let candidates = [
            lib.appendingPathComponent(gstreamer).path,
            "/Library/Frameworks/\(gstreamer)",
            lib.appendingPathComponent("libgstreamer-1.0.0.dylib").path,
        ]
        return candidates.contains(where: fileExists) ? .available : .missingGStreamer
    }

    public func version() async -> String? {
        guard let result = try? await ProcessRunner.run(wineBinary, arguments: ["--version"]),
              result.exitCode == 0 else { return nil }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum WineRuntimeLocator {
    /// 常见的系统 Wine 安装位置。
    static let systemCandidates: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths: [String] = []
        for root in ["/Applications", "\(home)/Applications"] {
            for app in ["Wine Stable", "Wine Devel", "Wine Staging"] {
                paths.append("\(root)/\(app).app/Contents/Resources/wine/bin/wine")
                paths.append("\(root)/\(app).app/Contents/Resources/wine/bin/wine64")
            }
        }
        paths += ["/opt/homebrew/bin/wine", "/usr/local/bin/wine", "/usr/local/bin/wine64"]
        return paths
    }()

    /// 列出所有找得到的运行时：Kazusa 管理的优先，其次系统的。
    public static func discover(paths: KazusaPaths, customBinary: String? = nil) -> [WineRuntime] {
        let fm = FileManager.default
        var found: [WineRuntime] = []

        if let customBinary, !customBinary.isEmpty, fm.isExecutableFile(atPath: customBinary) {
            found.append(WineRuntime(wineBinary: URL(fileURLWithPath: customBinary), source: .custom))
        }

        // Runtimes/<name>/bin/wine
        if let entries = try? fm.contentsOfDirectory(at: paths.runtimesDir, includingPropertiesForKeys: nil) {
            for dir in entries.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
                for name in ["wine", "wine64"] {
                    let bin = dir.appendingPathComponent("bin/\(name)")
                    if fm.isExecutableFile(atPath: bin.path) {
                        found.append(WineRuntime(wineBinary: bin, source: .managed))
                        break
                    }
                }
            }
        }

        var seenBinDirs = Set(found.map(\.binDirectory.path))
        for path in systemCandidates where fm.isExecutableFile(atPath: path) {
            let runtime = WineRuntime(wineBinary: URL(fileURLWithPath: path), source: .system)
            if seenBinDirs.insert(runtime.binDirectory.path).inserted {
                found.append(runtime)
            }
        }
        return found
    }
}

public enum RuntimeInstaller {
    public enum InstallError: LocalizedError {
        case extractFailed(String)
        case noWineBinary

        public var errorDescription: String? {
            switch self {
            case .extractFailed(let log): "解压失败：\(log)"
            case .noWineBinary: "压缩包里没有找到 bin/wine 或 bin/wine64"
            }
        }
    }

    /// 把一个 Wine 构建的压缩包（.tar.xz / .tar.gz / .zip）安装到 Runtimes/<name>。
    /// 压缩包里只要某一层目录下有 bin/wine 即可。
    public static func install(archive: URL, name: String, paths: KazusaPaths) async throws -> WineRuntime {
        try paths.ensureDirectories()
        let fm = FileManager.default
        let staging = paths.runtimesDir.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let result: ProcessResult
        if archive.pathExtension.lowercased() == "zip" {
            result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", archive.path, staging.path])
        } else {
            result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-xf", archive.path, "-C", staging.path])
        }
        guard result.exitCode == 0 else { throw InstallError.extractFailed(result.output) }

        guard let wineRoot = findWineRoot(in: staging, depth: 4) else { throw InstallError.noWineBinary }

        let destination = paths.runtimesDir.appendingPathComponent(name, isDirectory: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: wineRoot, to: destination)

        // 去掉下载带来的隔离属性，否则 Gatekeeper 会拦住每个 dylib。
        _ = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/xattr"), arguments: ["-dr", "com.apple.quarantine", destination.path])

        let bin = ["wine", "wine64"].map { destination.appendingPathComponent("bin/\($0)") }
            .first { fm.isExecutableFile(atPath: $0.path) }
        guard let bin else { throw InstallError.noWineBinary }
        return WineRuntime(wineBinary: bin, source: .managed)
    }

    static func findWineRoot(in dir: URL, depth: Int) -> URL? {
        let fm = FileManager.default
        for name in ["wine", "wine64"] where fm.isExecutableFile(atPath: dir.appendingPathComponent("bin/\(name)").path) {
            return dir
        }
        guard depth > 0,
              let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        for child in children where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if let found = findWineRoot(in: child, depth: depth - 1) { return found }
        }
        return nil
    }
}

public enum SystemCheck {
    /// Wine 的 macOS 构建是 x86_64 的，在 Apple Silicon 上需要 Rosetta 2。
    public static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    public static var isRosettaInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
    }

    public static let rosettaInstallCommand = "softwareupdate --install-rosetta --agree-to-license"
}
