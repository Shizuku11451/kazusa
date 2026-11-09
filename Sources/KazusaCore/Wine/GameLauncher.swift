// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation

public struct GameExit: Sendable {
    public var gameID: UUID
    public var exitCode: Int32
    public var startedAt: Date
    public var duration: TimeInterval
    public var logFile: URL
}

/// 启动 / 停止游戏，记录日志和游玩时长。
public actor GameLauncher {
    private struct Session {
        var process: Process
        /// Wine 会话才有：停止时要用同一套环境变量调 wineserver -k。
        var wine: (runtime: WineRuntime, environment: [String: String])?
    }

    private let paths: KazusaPaths
    private var sessions: [UUID: Session] = [:]

    public init(paths: KazusaPaths) {
        self.paths = paths
    }

    public enum LaunchError: LocalizedError {
        case alreadyRunning
        case executableMissing(String)

        public var errorDescription: String? {
            switch self {
            case .alreadyRunning: "游戏已经在运行"
            case .executableMissing(let path): "找不到游戏程序：\(path)"
            }
        }
    }

    public func isRunning(_ id: UUID) -> Bool { sessions[id] != nil }

    /// Wine 会话用的运行时和环境变量（文本钩子要在同一个前缀里运行）。原生会话返回 nil。
    public func wineContext(for id: UUID) -> (runtime: WineRuntime, environment: [String: String])? {
        sessions[id]?.wine
    }

    public func logFile(for id: UUID) -> URL {
        paths.logsDir.appendingPathComponent("\(id.uuidString).log")
    }

    /// - Parameter onExit: 进程退出时回调（在任意线程）。
    public func launch(
        _ game: Game,
        runtime: WineRuntime,
        cjkFont: String,
        onExit: @escaping @Sendable (GameExit) -> Void
    ) async throws {
        guard sessions[game.id] == nil else { throw LaunchError.alreadyRunning }
        let exe = game.executableURL
        guard !game.executable.isEmpty, FileManager.default.fileExists(atPath: exe.path) else {
            throw LaunchError.executableMissing(exe.path)
        }
        try paths.ensureDirectories()

        // 先修运行时，再建 / 更新前缀，最后补前缀里的副本（见 RosettaWoW64Fix）。
        let runtimeFix = try await RosettaWoW64Fix.applyToRuntime(runtime, paths: paths)
        let prefix = WinePrefix(name: game.prefixName, paths: paths)
        try await prefix.prepare(runtime: runtime, locale: game.locale, cjkFont: cjkFont)
        let prefixFix = try await RosettaWoW64Fix.applyToPrefix(prefix.url, runtime: runtime, paths: paths)
        // 汉化版常要求“先安装 font.ttf”：自动装进前缀。
        try prefix.installFonts(from: game.directory, tag: String(game.id.uuidString.prefix(8)))

        let env = WineEnvironment.make(runtime: runtime, prefix: prefix.url, locale: game.locale, extra: game.environment)
        let logURL = logFile(for: game.id)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        let header = "=== Kazusa \(Date()) ===\nruntime: \(runtime.wineBinary.path)\nprefix: \(prefix.url.path)\nlocale: \(game.locale.posixLocale)\nexe: \(exe.path)\nwow64cpu fix: runtime \(runtimeFix), prefix \(prefixFix)\n\n"
        log.write(Data(header.utf8))

        // 很多 galgame 用相对路径读资源，工作目录必须是 exe 所在目录。
        let process = try start(game, program: runtime.wineBinary, arguments: [exe.path] + game.arguments,
                                environment: env, workingDirectory: exe.deletingLastPathComponent(),
                                log: log, logURL: logURL, onExit: onExit)
        sessions[game.id] = Session(process: process, wine: (runtime, env))
    }

    /// 用打包的原生引擎（ONScripter / krkr2）启动，不经过 Wine。
    public func launchNative(
        _ game: Game,
        binary: URL,
        arguments: [String],
        onExit: @escaping @Sendable (GameExit) -> Void
    ) async throws {
        guard sessions[game.id] == nil else { throw LaunchError.alreadyRunning }
        guard FileManager.default.fileExists(atPath: game.directory.path) else {
            throw LaunchError.executableMissing(game.directory.path)
        }
        try paths.ensureDirectories()
        var env = ProcessInfo.processInfo.environment
        env["LANG"] = game.locale.posixLocale
        env.merge(game.environment) { $1 }

        let logURL = logFile(for: game.id)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        let quoted = arguments.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
        let header = "=== Kazusa \(Date()) ===\nbackend: native\nengine: \(binary.path)\nargs: \(quoted)\n\n"
        log.write(Data(header.utf8))

        let process = try start(game, program: binary, arguments: arguments, environment: env,
                                workingDirectory: game.directory, log: log, logURL: logURL, onExit: onExit)
        sessions[game.id] = Session(process: process, wine: nil)
    }

    private func start(
        _ game: Game,
        program: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        log: FileHandle,
        logURL: URL,
        onExit: @escaping @Sendable (GameExit) -> Void
    ) throws -> Process {
        let process = Process()
        process.executableURL = program
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = log
        process.standardError = log

        let startedAt = Date()
        let gameID = game.id
        process.terminationHandler = { [weak self] p in
            try? log.close()
            let exit = GameExit(
                gameID: gameID,
                exitCode: p.terminationStatus,
                startedAt: startedAt,
                duration: Date().timeIntervalSince(startedAt),
                logFile: logURL
            )
            Task { await self?.didExit(gameID) }
            onExit(exit)
        }
        try process.run()
        return process
    }

    /// 结束游戏：先礼貌地终止；Wine 游戏再杀掉前缀里的 wineserver（会结束同前缀的所有 Windows 进程）。
    public func stop(_ id: UUID) async {
        guard let session = sessions[id] else { return }
        session.process.terminate()
        guard let wine = session.wine else { return }
        _ = try? await ProcessRunner.run(wine.runtime.wineserver, arguments: ["-k"], environment: wine.environment)
    }

    private func didExit(_ id: UUID) {
        sessions[id] = nil
    }
}
