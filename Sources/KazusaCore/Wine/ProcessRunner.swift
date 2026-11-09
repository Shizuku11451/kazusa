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
        return LegacyText.decode(data)
    }
}

/// Windows 程序（cmd、regedit 等）按当前区域的 ANSI 代码页输出，不一定是 UTF-8。
public enum LegacyText {
    static let fallbacks: [String.Encoding] = [
        .shiftJIS,
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))),
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))),
    ]

    /// 先试 UTF-8，失败再依次试 Shift-JIS、GB18030、Big5，都不行就有损解码。
    public static func decode(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        for encoding in fallbacks {
            if let s = String(data: data, encoding: encoding) { return s }
        }
        return String(decoding: data, as: UTF8.self)
    }
}
