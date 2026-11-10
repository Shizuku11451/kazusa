// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation

/// 在游戏的 Wine 前缀里运行 `kazusa-hook32/64.exe`，把 LunaHook 注入游戏，按行读回事件。
///
/// 钩子程序和游戏必须用同一个前缀（同一个 wineserver），位数和游戏一致。
public final class TextHookHost: @unchecked Sendable {
    public enum HostError: LocalizedError {
        case unknownArchitecture(String)
        case filesMissing(String)

        public var errorDescription: String? {
            switch self {
            case .unknownArchitecture(let path): "读不出游戏程序的位数：\(path)"
            case .filesMissing(let arch): "找不到 \(arch) 位的文本钩子组件（kazusa-hook / LunaHook）"
            }
        }
    }

    /// 一套钩子文件：`kazusa-hookNN.exe` 和同位数的 LunaHost/LunaHook DLL 所在目录。
    public struct Files: Equatable, Sendable {
        public var executable: URL
        public var dllDirectory: URL
    }

    private let lock = NSLock()
    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var stopped = false

    public init() {}

    /// 候选位置：.app 里的 `Resources/texthook/`，开发时用仓库里的预编译文件。
    public static func files(for arch: PEImage.Architecture, bundle: URL? = Bundle.main.resourceURL) -> Files? {
        let bits = arch == .x86 ? "32" : "64"
        let sub = arch == .x86 ? "x86" : "x64"
        var candidates: [Files] = []
        if let bundle {
            let root = bundle.appendingPathComponent("texthook", isDirectory: true)
            candidates.append(Files(executable: root.appendingPathComponent("kazusa-hook\(bits).exe"),
                                    dllDirectory: root.appendingPathComponent(sub, isDirectory: true)))
        }
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // TextHook
            .deletingLastPathComponent() // KazusaCore
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent()
        candidates.append(Files(
            executable: repo.appendingPathComponent("HookHost/prebuilt/kazusa-hook\(bits).exe"),
            dllDirectory: repo.appendingPathComponent("ThirdParty/lunahook/prebuilt/\(sub)", isDirectory: true)))
        let fm = FileManager.default
        return candidates.first {
            fm.fileExists(atPath: $0.executable.path)
                && fm.fileExists(atPath: $0.dllDirectory.appendingPathComponent("LunaHost\(bits).dll").path)
                && fm.fileExists(atPath: $0.dllDirectory.appendingPathComponent("LunaHook\(bits).dll").path)
        }
    }

    /// Wine 里的 unix 路径：`/a/b` → `Z:\a\b`。
    public static func windowsPath(_ url: URL) -> String {
        "Z:" + url.standardizedFileURL.path.replacingOccurrences(of: "/", with: "\\")
    }

    /// 启动钩子程序。它会等游戏进程出现（最多 `wait` 秒）再注入。
    /// - Parameter onEvent: 每个事件回调一次（在后台线程）；钩子程序退出时回调 `nil`。
    public func start(
        game: Game,
        runtime: WineRuntime,
        environment: [String: String],
        wait: Int = 120,
        onEvent: @escaping @Sendable (HookEvent?) -> Void
    ) throws {
        let exe = game.executableURL
        guard let arch = PEImage.architecture(of: exe) else { throw HostError.unknownArchitecture(exe.path) }
        guard let files = Self.files(for: arch) else { throw HostError.filesMissing(arch == .x86 ? "32" : "64") }

        let process = Process()
        process.executableURL = runtime.wineBinary
        process.arguments = [
            files.executable.path,
            "--name", exe.lastPathComponent,
            "--codepage", String(game.locale.codepage),
            "--dll-dir", Self.windowsPath(files.dllDirectory),
            "--wait", String(wait),
        ]
        var env = environment
        env["WINEDEBUG"] = "-all"
        process.environment = env
        process.currentDirectoryURL = files.executable.deletingLastPathComponent()

        // 钩子程序读到 stdin 的 EOF 就会断开，所以这根管子要一直开着，停止时再关。
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else { return }
            for line in self.appendLines(chunk) {
                if let event = HookEvent.parse(line) { onEvent(event) }
            }
        }
        process.terminationHandler = { _ in
            output.fileHandleForReading.readabilityHandler = nil
            onEvent(nil)
        }
        try process.run()
        lock.withLock {
            self.process = process
            self.stdin = input.fileHandleForWriting
        }
    }

    private func appendLines(_ chunk: Data) -> [String] {
        lock.withLock {
            buffer.append(chunk)
            var lines: [String] = []
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                if let line = String(data: lineData, encoding: .utf8) {
                    lines.append(line.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            return lines
        }
    }

    /// 手动插入特殊码（H-code）。
    public func insertHook(_ code: String) {
        send("hook \(code)\n")
    }

    private func send(_ command: String) {
        lock.withLock {
            guard !stopped else { return }
            try? stdin?.write(contentsOf: Data(command.utf8))
        }
    }

    /// 让钩子程序从游戏断开并退出；2 秒内没退就强制结束。
    public func stop() {
        let process: Process? = lock.withLock {
            guard !stopped else { return nil }
            try? stdin?.write(contentsOf: Data("quit\n".utf8))
            try? stdin?.close()
            stopped = true
            return self.process
        }
        guard let process else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { process.terminate() }
        }
    }
}
