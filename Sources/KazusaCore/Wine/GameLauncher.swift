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
        var prefix: URL
        var environment: [String: String]
        var runtime: WineRuntime
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
        guard FileManager.default.fileExists(atPath: exe.path) else {
            throw LaunchError.executableMissing(exe.path)
        }
        try paths.ensureDirectories()

        let prefix = WinePrefix(name: game.prefixName, paths: paths)
        try await prefix.prepare(runtime: runtime, locale: game.locale, cjkFont: cjkFont)

        let env = WineEnvironment.make(runtime: runtime, prefix: prefix.url, locale: game.locale, extra: game.environment)
        let logURL = logFile(for: game.id)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        let header = "=== Kazusa \(Date()) ===\nruntime: \(runtime.wineBinary.path)\nprefix: \(prefix.url.path)\nlocale: \(game.locale.posixLocale)\nexe: \(exe.path)\n\n"
        log.write(Data(header.utf8))

        let process = Process()
        process.executableURL = runtime.wineBinary
        process.arguments = [exe.path] + game.arguments
        process.environment = env
        // 很多 galgame 用相对路径读资源，工作目录必须是 exe 所在目录。
        process.currentDirectoryURL = exe.deletingLastPathComponent()
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
        sessions[game.id] = Session(process: process, prefix: prefix.url, environment: env, runtime: runtime)
    }

    /// 结束游戏：先礼貌地终止，再杀掉前缀里的 wineserver（会结束同前缀的所有 Windows 进程）。
    public func stop(_ id: UUID) async {
        guard let session = sessions[id] else { return }
        session.process.terminate()
        _ = try? await ProcessRunner.run(session.runtime.wineserver, arguments: ["-k"], environment: session.environment)
    }

    private func didExit(_ id: UUID) {
        sessions[id] = nil
    }
}
