// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation

/// 一路文本（LunaHook 里叫 text thread）：同一个钩子在不同调用位置输出的文本会分成不同的线程，
/// 比如对白一路、人名一路。
public struct HookThread: Equatable, Sendable, Identifiable {
    /// `pid:addr:ctx:ctx2`
    public var id: String
    public var hookcode: String
    public var name: String

    public init(id: String, hookcode: String, name: String) {
        self.id = id
        self.hookcode = hookcode
        self.name = name
    }
}

/// `kazusa-hook.exe` 输出的一行事件，见 HookHost/kazusa-hook.c。
public enum HookEvent: Equatable, Sendable {
    /// 已和游戏里的钩子建立连接。
    case ready(pid: Int)
    case thread(HookThread)
    case threadRemoved(id: String)
    case text(threadID: String, text: String)
    case hookInserted(hookcode: String)
    /// LunaHook 的日志；level 4 是识别到的引擎名。
    case info(level: Int, message: String)
    case detached(pid: Int)
    case error(String)

    private struct Raw: Decodable {
        var type: String
        var pid: Int?
        var id: String?
        var hookcode: String?
        var name: String?
        var text: String?
        var level: Int?
        var message: String?
    }

    /// 解析一行输出。LunaHost 偶尔会往标准输出打调试信息，不是 JSON 的行返回 nil。
    public static func parse(_ line: some StringProtocol) -> HookEvent? {
        guard line.first == "{",
              let raw = try? JSONDecoder().decode(Raw.self, from: Data(line.utf8))
        else { return nil }
        switch raw.type {
        case "ready": return raw.pid.map { .ready(pid: $0) }
        case "thread":
            guard let id = raw.id else { return nil }
            return .thread(HookThread(id: id, hookcode: raw.hookcode ?? "", name: raw.name ?? ""))
        case "thread_removed": return raw.id.map { .threadRemoved(id: $0) }
        case "text":
            guard let id = raw.id, let text = raw.text else { return nil }
            return .text(threadID: id, text: text)
        case "hook_inserted": return .hookInserted(hookcode: raw.hookcode ?? "")
        case "info": return .info(level: raw.level ?? 0, message: raw.message ?? "")
        case "detached": return raw.pid.map { .detached(pid: $0) }
        case "error": return .error(raw.message ?? "未知错误")
        default: return nil
        }
    }
}

/// 读 PE 头判断 exe 的位数，用来选 32 / 64 位的钩子程序。
public enum PEImage {
    public enum Architecture: Equatable, Sendable { case x86, x64 }

    public static func architecture(of url: URL) -> Architecture? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096) else { return nil }
        return architecture(header: data)
    }

    static func architecture(header data: Data) -> Architecture? {
        let bytes = [UInt8](data)
        func u16(_ i: Int) -> Int? { i + 1 < bytes.count ? Int(bytes[i]) | Int(bytes[i + 1]) << 8 : nil }
        func u32(_ i: Int) -> Int? {
            guard let lo = u16(i), let hi = u16(i + 2) else { return nil }
            return lo | hi << 16
        }
        guard bytes.count > 0x40, bytes[0] == 0x4D, bytes[1] == 0x5A, let pe = u32(0x3C),
              pe + 6 <= bytes.count, bytes[pe] == 0x50, bytes[pe + 1] == 0x45, bytes[pe + 2] == 0, bytes[pe + 3] == 0,
              let machine = u16(pe + 4)
        else { return nil }
        switch machine {
        case 0x014C: return .x86
        case 0x8664: return .x64
        default: return nil
        }
    }
}
