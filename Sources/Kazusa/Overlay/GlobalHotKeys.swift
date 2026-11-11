// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Carbon.HIToolbox

/// 系统级快捷键：游戏在前台时也能触发。
///
/// 用 Carbon 的 `RegisterEventHotKey`，不需要“辅助功能”权限（`NSEvent` 全局监听需要），
/// 而且按键会被我们独占，不会再传给游戏。
@MainActor
final class GlobalHotKeys {
    struct Combo {
        var keyCode: Int
        var modifiers: Int
        var display: String

        /// ⇧⌘R
        static let recognize = Combo(keyCode: kVK_ANSI_R, modifiers: cmdKey | shiftKey, display: "⇧⌘R")
        /// ⇧⌘L
        static let toggleLock = Combo(keyCode: kVK_ANSI_L, modifiers: cmdKey | shiftKey, display: "⇧⌘L")
        /// ⇧⌘U
        static let upscale = Combo(keyCode: kVK_ANSI_U, modifiers: cmdKey | shiftKey, display: "⇧⌘U")
    }

    static let shared = GlobalHotKeys()

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 1

    private init() {}

    /// 注册一个快捷键。返回 false 表示已被其他应用占用。
    @discardableResult
    func register(_ combo: Combo, action: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4B5A_5341), id: id) // 'KZSA'
        let status = RegisterEventHotKey(UInt32(combo.keyCode), UInt32(combo.modifiers), hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs.append(ref)
        actions[id] = action
        return true
    }

    fileprivate func fire(_ id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr else { return status }
            let id = hotKeyID.id
            // Carbon 事件在主线程分发。
            MainActor.assumeIsolated { GlobalHotKeys.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}
