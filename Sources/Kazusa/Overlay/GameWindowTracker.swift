// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import AppKit
import CoreGraphics
import KazusaCore

/// 盯着游戏窗口的位置，让字幕条跟着游戏窗口走。
///
/// 用 CGWindowList 轮询：窗口位置和所属进程不需要录屏权限，也不需要辅助功能权限。
@MainActor
final class GameWindowTracker {
    private let executable: URL?
    private let onChange: (_ old: NSRect?, _ new: NSRect) -> Void
    private var task: Task<Void, Never>?
    private var pids: [pid_t] = []
    private var lastPIDScan = Date.distantPast
    private(set) var frame: NSRect?

    /// - Parameters:
    ///   - executable: Wine 游戏的 exe，按它找 Wine 里的游戏进程。
    ///   - pid: 已知的游戏进程（原生引擎），给了就只看这个进程。
    ///   - onChange: 游戏窗口第一次找到（old 为 nil）或位置、大小变了时回调，坐标是 AppKit 屏幕坐标。
    init(executable: URL?, pid: pid_t? = nil, onChange: @escaping (_ old: NSRect?, _ new: NSRect) -> Void) {
        self.executable = executable
        self.pids = pid.map { [$0] } ?? []
        self.onChange = onChange
    }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func tick() {
        var found = Self.mainWindow(of: pids)
        // 游戏刚启动、换了进程（启动器拉起主程序）时重新找进程，最多两秒找一次。
        if found == nil, let exe = executable, Date().timeIntervalSince(lastPIDScan) > 2 {
            lastPIDScan = Date()
            pids = WineProcess.pids(running: exe)
            found = Self.mainWindow(of: pids)
        }
        guard let found, found != frame else { return }
        let old = frame
        frame = found
        onChange(old, found)
    }

    /// 这些进程在屏幕上最大的普通窗口。
    private static func mainWindow(of pids: [pid_t]) -> NSRect? {
        guard !pids.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }
        let best = list.lazy
            .filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
            .filter { pids.contains(pid_t(($0[kCGWindowOwnerPID as String] as? Int) ?? -1)) }
            .compactMap { info -> CGRect? in
                guard let dict = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
                return CGRect(dictionaryRepresentation: dict)
            }
            .filter { $0.width >= 200 && $0.height >= 150 }
            .max { $0.width * $0.height < $1.width * $1.height }
        return best.map(appKitRect)
    }

    /// CGWindowList 的坐标原点在主屏左上角、y 向下；AppKit 的在主屏左下角、y 向上。
    static func appKitRect(_ rect: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
