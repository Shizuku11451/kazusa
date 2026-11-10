// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Darwin
import Foundation

/// 找 Wine 里跑着的 Windows 程序对应的 macOS 进程。
///
/// Wine 把每个 Windows 进程的 argv[0] 设成它的 Windows 路径（如 `Z:\Users\me\Games\WA2\WA2.exe`），
/// 窗口列表里的进程名却都是 `wine`，所以按 argv[0] 认。
public enum WineProcess {
    /// 运行 `executable` 的进程号。路径完全一致的优先；没有的话退一步按文件名找。
    public static func pids(running executable: URL) -> [pid_t] {
        let candidates = allPIDs().compactMap { pid in argv0(of: pid).map { (pid, $0) } }
        return match(candidates, executable: executable)
    }

    static func match(_ candidates: [(pid_t, String)], executable: URL) -> [pid_t] {
        let full = TextHookHost.windowsPath(executable).lowercased()
        let exact = candidates.filter { $0.1.lowercased() == full }.map(\.0)
        if !exact.isEmpty { return exact }
        let name = "\\" + executable.lastPathComponent.lowercased()
        return candidates.filter { $0.1.lowercased().hasSuffix(name) }.map(\.0)
    }

    private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let n = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return n > 0 ? Array(pids.prefix(Int(n))).filter { $0 > 0 } : []
    }

    /// 读进程的 argv[0]（KERN_PROCARGS2：argc，执行路径，若干 \0，然后是 argv）。别的用户的进程读不到。
    private static func argv0(of pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        var i = MemoryLayout<Int32>.size
        while i < size, buffer[i] != 0 { i += 1 } // 执行路径
        while i < size, buffer[i] == 0 { i += 1 }
        let start = i
        while i < size, buffer[i] != 0 { i += 1 }
        guard i > start else { return nil }
        return String(decoding: buffer[start..<i], as: UTF8.self)
    }
}
