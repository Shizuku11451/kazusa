// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import AppKit
import SwiftUI

@main
struct KazusaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Kazusa") {
            LibraryView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 520)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("添加游戏…") { model.presentImportPanel() }
                    .keyboardShortcut("o")
            }
            CommandMenu("游戏") {
                let game = model.selectedGame
                let running = game.map { model.runningGameIDs.contains($0.id) } ?? false
                Button("启动") { if let game { model.launch(game) } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(game == nil || running)
                Button("停止…") { if let game { model.confirmingStop = .init(id: game.id) } }
                    .disabled(!running)
                Divider()
                // 系统级快捷键，游戏在前台时按才有意义（放大最前面的窗口）。
                Button("画面放大 开 / 关（\(GlobalHotKeys.Combo.upscale.display)）") { model.toggleUpscale() }
                Divider()
                Button("游戏设置…") { if let game { model.gameSettings = .init(id: game.id) } }
                    .keyboardShortcut("i")
                    .disabled(game == nil)
                Button("在 Finder 中显示") { if let game { NSWorkspace.shared.activateFileViewerSelecting([game.executableURL]) } }
                    .disabled(game == nil)
                Divider()
                Button("从游戏库移除…") { if let game { model.confirmingRemoval = .init(id: game.id) } }
                    .disabled(game == nil)
            }
            CommandMenu("翻译") {
                Button("打开翻译悬浮窗") { model.overlay.show(game: model.selectedGame) }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                // ⇧⌘R / ⇧⌘L 是系统级快捷键（GlobalHotKeys），游戏在前台也能用，这里不再重复绑定。
                Button("识别并翻译（\(GlobalHotKeys.Combo.recognize.display)）") { model.overlay.captureOnce() }
                Button("锁定 / 解锁悬浮窗（\(GlobalHotKeys.Combo.toggleLock.display)）") { model.overlay.toggleLock() }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 用 `swift run` 直接启动时没有 .app 包，需要手动变成前台应用才能显示菜单和窗口。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
