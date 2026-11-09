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
            CommandMenu("翻译") {
                Button("打开翻译悬浮窗") { model.overlay.show(game: model.selectedGame) }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("识别并翻译") { model.overlay.captureOnce() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
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
