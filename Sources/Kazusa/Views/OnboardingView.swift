// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import KazusaCore
import SwiftUI

/// 第一次打开时的引导：介绍 → 运行环境 → 翻译服务 → 添加游戏。每一步都能跳过，以后在设置里改。
struct OnboardingView: View {
    static let doneKey = "onboardingDone"

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var apiKey = ""

    private let titles = ["欢迎使用 Kazusa", "运行环境", "翻译服务", "添加第一个游戏"]

    var body: some View {
        VStack(spacing: 0) {
            Text(titles[step])
                .font(.title2.bold())
                .padding(.top, 24)
            Group {
                switch step {
                case 0: welcome
                case 1: environment
                case 2: translation
                default: addGame
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                if step < titles.count - 1 {
                    Button("跳过引导") { finish() }
                }
                Spacer()
                Text("\(step + 1) / \(titles.count)").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if step > 0 {
                    Button("上一步") { step -= 1 }
                }
                if step < titles.count - 1 {
                    Button("继续") { step += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("稍后再添加") { finish() }
                    Button("添加游戏…") {
                        finish()
                        model.presentImportPanel()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .frame(width: 560, height: 460)
        .onChange(of: step) { old, _ in if old == 2 { saveKey() } }
        // 按 Esc 关掉也算看过了。
        .onDisappear {
            saveKey()
            UserDefaults.standard.set(true, forKey: Self.doneKey)
        }
        // 游戏库窗口的提示框在引导盖着时弹不出来，下载失败等错误在这里显示。
        .alert(model.alert?.title ?? "", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
               presenting: model.alert) { _ in
            Button("好", role: .cancel) {}
        } message: { Text($0.message) }
        .onAppear { apiKey = model.settings.activeProvider.flatMap { APIKeyStore.shared.apiKey(for: $0.id) } ?? "" }
    }

    private func finish() { dismiss() }

    // MARK: - 步骤

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 72, height: 72)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            feature("play.fill", .green, "在 Mac 上玩 Windows 版 galgame",
                    "NScripter 和 KiriKiri 游戏原生运行，其他游戏用 Wine 运行。")
            feature("character.bubble.fill", .purple, "边玩边翻译",
                    "读出游戏里的台词，交给大模型翻译，显示在游戏窗口下方的字幕条里。")
            feature("books.vertical.fill", .orange, "游戏库",
                    "自动找封面和简介，记录游玩时长，备份存档。")
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 20)
    }

    private func feature(_ symbol: String, _ color: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            SettingsIcon(symbol, color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var environment: some View {
        Form {
            Section {
                if SystemCheck.isAppleSilicon {
                    StatusRow(symbol: "cpu", color: .gray, title: "Rosetta 2",
                              status: model.rosettaInstalled ? "已安装" : "未安装", ok: model.rosettaInstalled) {
                        if !model.rosettaInstalled {
                            Button("安装…") { model.installRosetta() }
                                .disabled(model.busyMessage != nil)
                                .help("会要求输入登录密码")
                        }
                    }
                }
                StatusRow(symbol: "wineglass.fill", color: .red, title: "Wine",
                          status: model.currentRuntime.map { "已安装 · \($0.displayName)" }
                              ?? "未安装（约 \(RuntimeInstaller.recommended.sizeMB) MB）",
                          ok: model.currentRuntime != nil) {
                    if model.currentRuntime == nil {
                        Button("下载安装") { model.installRecommendedRuntime() }
                            .disabled(model.busyMessage != nil)
                    }
                }
                if let message = model.busyMessage {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(message)
                    }
                }
            } footer: {
                Text("只玩 NScripter 和 KiriKiri 游戏可以先跳过：它们原生运行，不需要这两样。以后第一次启动要用 Wine 的游戏时，Kazusa 也会提示安装。")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }

    private var translation: some View {
        @Bindable var model = model
        return Form {
            Section {
                Picker("翻译服务", selection: Binding(
                    get: { model.settings.activeProvider?.id },
                    set: { id in
                        saveKey()
                        model.settings.activeProviderID = id
                        apiKey = id.flatMap { APIKeyStore.shared.apiKey(for: $0) } ?? ""
                    }
                )) {
                    ForEach(model.settings.providers) { Text($0.name).tag(Optional($0.id)) }
                }
                if let provider = model.settings.activeProvider {
                    LabeledContent("模型", value: provider.model)
                    SecureField("API Key", text: $apiKey, prompt: Text(provider.baseURL.contains("localhost") ? "本地服务不用填" : "必填"))
                }
            } footer: {
                Text("翻译要用大模型服务：填好 API Key 就能用，也可以用 Ollama、LM Studio 在本机运行。模型、提示词和更多服务以后在“设置 → 翻译”里改。")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                StatusRow(symbol: "rectangle.dashed.badge.record", color: .red, title: "屏幕录制权限（可选）",
                          status: ScreenTextCapture.hasPermission ? "已授权" : "未授权",
                          ok: ScreenTextCapture.hasPermission) {
                    if !ScreenTextCapture.hasPermission {
                        Button("请求授权") { ScreenTextCapture.requestPermission() }
                    }
                }
            } footer: {
                Text("读不到台词的游戏可以截屏识别文字（OCR）再翻译，这需要屏幕录制权限。")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }

    private var addGame: some View {
        VStack(alignment: .leading, spacing: 18) {
            feature("folder.fill", .blue, "选择游戏文件夹",
                    "点“添加游戏…”选游戏所在的文件夹（或里面的 .exe），也可以直接拖到游戏库窗口里。汉化版和日文原版都可以。")
            feature("wand.and.stars", .teal, "自动识别",
                    "Kazusa 会认出游戏引擎、主程序和语言，选好运行方式，并找封面和简介。认错了可以在“游戏设置”（⌘I）里改。")
            feature("play.fill", .green, "启动和翻译",
                    "点封面打开游戏，再点“启动”（⌘↩）。游戏运行时按 ⇧⌘T 打开翻译悬浮窗。")
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 20)
    }

    private func saveKey() {
        guard let id = model.settings.activeProvider?.id,
              (APIKeyStore.shared.apiKey(for: id) ?? "") != apiKey else { return }
        APIKeyStore.shared.setAPIKey(apiKey, for: id)
        model.overlay.settingsDidChange()
    }
}
