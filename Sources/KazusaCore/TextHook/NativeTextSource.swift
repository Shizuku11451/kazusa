// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Darwin
import Foundation

/// 从原生引擎读出显示的台词：引擎把每句话按和 `kazusa-hook.exe` 一样的 JSON 行格式
/// 写进环境变量 `KAZUSA_TEXT_PIPE` 指定的命名管道（见 ThirdParty/onscripter-yuri/kazusa.patch）。
///
/// 管道由这边先建好并以读写方式打开：引擎那头打开时不会阻塞，引擎退出后也不会读到 EOF，
/// 停止时关掉并删除。
public final class NativeTextSource: @unchecked Sendable {
    public static let environmentKey = "KAZUSA_TEXT_PIPE"

    public enum SourceError: LocalizedError {
        case cannotCreatePipe(String)

        public var errorDescription: String? {
            switch self {
            case .cannotCreatePipe(let reason): "没能建立和引擎通信的管道：\(reason)"
            }
        }
    }

    public let pipeURL: URL
    private let fd: Int32
    private let source: DispatchSourceRead
    private let lock = NSLock()
    private var buffer = Data()
    private var stopped = false

    /// 建好管道并开始读。事件在后台队列回调。
    public init(directory: URL = FileManager.default.temporaryDirectory,
                onEvent: @escaping @Sendable (HookEvent) -> Void) throws {
        let url = directory.appendingPathComponent("kazusa-text-\(UUID().uuidString).fifo")
        guard mkfifo(url.path, 0o600) == 0 else {
            throw SourceError.cannotCreatePipe(String(cString: strerror(errno)))
        }
        let fd = open(url.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            let reason = String(cString: strerror(errno))
            unlink(url.path)
            throw SourceError.cannotCreatePipe(reason)
        }
        pipeURL = url
        self.fd = fd
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "kazusa.native-text"))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            for line in self.readLines() {
                if let event = HookEvent.parse(line) { onEvent(event) }
            }
        }
        source.setCancelHandler {
            close(fd)
            unlink(url.path)
        }
        source.resume()
    }

    deinit { stop() }

    /// 传给引擎的环境变量。
    public var environment: [String: String] { [Self.environmentKey: pipeURL.path] }

    private func readLines() -> [String] {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var lines: [String] = []
        lock.withLock {
            while true {
                let n = read(fd, &chunk, chunk.count)
                guard n > 0 else { break }
                buffer.append(contentsOf: chunk[0..<n])
            }
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                if let line = String(data: lineData, encoding: .utf8) {
                    lines.append(line.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
        return lines
    }

    /// 停止读取，关掉并删除管道。可以重复调用。
    public func stop() {
        let shouldCancel: Bool = lock.withLock {
            defer { stopped = true }
            return !stopped
        }
        if shouldCancel { source.cancel() }
    }
}
