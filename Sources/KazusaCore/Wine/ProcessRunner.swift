// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation

public struct ProcessResult: Sendable {
    public var exitCode: Int32
    public var output: String
}

public enum ProcessRunner {
    /// 运行一个命令并等待退出，合并 stdout/stderr。
    @discardableResult
    public static func run(
        _ executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let collector = OutputCollector()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            collector.append(handle.availableData)
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { p in
                pipe.fileHandleForReading.readabilityHandler = nil
                collector.append(pipe.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: ProcessResult(exitCode: p.terminationStatus, output: collector.string))
            }
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }

    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
