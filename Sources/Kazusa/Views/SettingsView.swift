// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import KazusaCore
import SwiftUI
import UniformTypeIdentifiers

/// 仿“系统设置”：左边带彩色图标的边栏，右边分组列表，点进去的页面有返回按钮。
struct SettingsView: View {
    static let windowID = "settings"
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { model.settingsTab },
                set: { if let tab = $0 { model.settingsTab = tab } }
            )) {
                ForEach(AppModel.SettingsTab.allCases, id: \.self) { tab in
                    Label { Text(tab.title) } icon: { SettingsIcon(tab.symbol, color: tab.color, size: 22) }
                        .tag(tab)
                }
            }
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(200)
        } detail: {
            NavigationStack {
                Group {
                    switch model.settingsTab {
                    case .system: SystemSettingsView()
                    case .runtime: RuntimeSettingsView()
                    case .fonts: FontSettingsView()
                    case .translation: TranslationSettingsView()
                    }
                }
                // 和系统设置一样，最上层也放一个灰掉的返回按钮：工具栏一直是同样高，点进下一层时布局不跳。
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button {} label: { Image(systemName: "chevron.left") }
                            .disabled(true)
                            .accessibilityLabel("返回")
                    }
                }
            }
            .navigationTitle(model.settingsTab.title)
            // 换页时回到这一页的最上层，不要停在上一页点进去的地方。
            .id(model.settingsTab)
        }
        .frame(width: 760, height: 560)
    }
}

/// 应用菜单里的“设置…”（⌘,）。
struct SettingsCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("设置…") { openWindow(id: SettingsView.windowID) }
            .keyboardShortcut(",")
    }
}

extension AppModel.SettingsTab {
    var title: String {
        switch self {
        case .system: "系统"
        case .runtime: "Wine 运行时"
        case .fonts: "字体"
        case .translation: "翻译"
        }
    }

    var symbol: String {
        switch self {
        case .system: "gearshape.fill"
        case .runtime: "wineglass.fill"
        case .fonts: "f.cursive"
        case .translation: "character.bubble.fill"
        }
    }

    var color: Color {
        switch self {
        case .system: .gray
        case .runtime: .red
        case .fonts: .blue
        case .translation: .purple
        }
    }
}

/// 系统设置里那种圆角方块图标。
struct SettingsIcon: View {
    let symbol: String
    let color: Color
    let size: CGFloat

    init(_ symbol: String, color: Color, size: CGFloat = 32) {
        self.symbol = symbol
        self.color = color
        self.size = size
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// 图标 + 标题 + 带彩色圆点的状态，右边放操作按钮（仿“网络”页）。
struct StatusRow<Trailing: View>: View {
    let symbol: String
    let color: Color
    let title: String
    let status: String
    let ok: Bool
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            SettingsIcon(symbol, color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                HStack(spacing: 5) {
                    Circle().fill(ok ? .green : .orange).frame(width: 7, height: 7)
                    Text(status).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer()
            trailing
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 系统

struct SystemSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppModel.autoCheckUpdatesKey) private var autoCheckUpdates = true

    var body: some View {
        Form {
            Section {
                if SystemCheck.isAppleSilicon {
                    StatusRow(symbol: "cpu", color: .gray, title: "Rosetta 2",
                              status: model.rosettaInstalled ? "已安装" : "未安装", ok: model.rosettaInstalled) {
                        if !model.rosettaInstalled {
                            Button("安装…") { model.installRosetta() }
                                .help("会要求输入登录密码")
                        }
                    }
                    if !model.rosettaInstalled {
                        HStack {
                            Text("也可以在终端运行：\(SystemCheck.rosettaInstallCommand)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Spacer()
                            Button("复制命令") { copy(SystemCheck.rosettaInstallCommand) }
                        }
                    }
                }
                StatusRow(symbol: "rectangle.dashed.badge.record", color: .red, title: "屏幕录制权限",
                          status: ScreenTextCapture.hasPermission ? "已授权" : "未授权",
                          ok: ScreenTextCapture.hasPermission) {
                    if !ScreenTextCapture.hasPermission {
                        Button("请求授权") { ScreenTextCapture.requestPermission() }
                    }
                }
            } footer: {
                Text("Rosetta 2 用来运行 Wine；原生运行的 NScripter 和 KiriKiri 游戏不需要。屏幕录制权限只有 OCR 翻译要用，文本钩子不需要。")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                StatusRow(symbol: "arrow.down.circle.fill", color: .blue, title: "Kazusa \(Self.version)",
                          status: autoCheckUpdates ? "自动检查更新已打开" : "自动检查更新已关闭", ok: autoCheckUpdates) {
                    Toggle("自动检查更新", isOn: $autoCheckUpdates).labelsHidden()
                    Button("立即检查") { model.checkForUpdates() }
                }
            } footer: {
                Text("每天最多查一次 GitHub 上的新版本，有新版本时提示下载。")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }
}

extension SystemSettingsView {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
}

// MARK: - Wine 运行时

struct RuntimeSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var versions: [String: String] = [:]

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                if model.runtimes.isEmpty {
                    StatusRow(symbol: "wineglass.fill", color: .red, title: "Wine", status: "没有找到", ok: false) {
                        EmptyView()
                    }
                } else {
                    // 没选过、或选的那个已经找不到时，实际用的是第一个；显示成“自动”，别让选择框空着。
                    Picker("使用", selection: Binding(
                        get: { model.runtimes.contains { $0.wineBinary.path == model.settings.selectedRuntimePath } ? model.settings.selectedRuntimePath : "" },
                        set: { model.settings.selectedRuntimePath = $0 }
                    )) {
                        Text("自动（\(label(for: model.runtimes[0]))）").tag("")
                        Divider()
                        ForEach(model.runtimes) { runtime in
                            Text(label(for: runtime)).tag(runtime.wineBinary.path)
                        }
                    }
                    if let selected = model.currentRuntime,
                       selected.videoDecoding != .available {
                        Label("视频解码\(selected.videoDecoding.summary)。游戏的 OP/ED 会黑屏。", systemImage: "film")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                if !hasRecommendedRuntime {
                    LabeledContent {
                        Button("下载安装") { model.installRecommendedRuntime() }
                            .disabled(model.busyMessage != nil)
                    } label: {
                        Text(RuntimeInstaller.recommended.name)
                        Text("约 \(RuntimeInstaller.recommended.sizeMB) MB。Kazusa 测试过这个版本，防 Rosetta 崩溃的修复也是给它编译的。")
                    }
                }
                if let message = model.busyMessage {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(message)
                    }
                }
            } footer: {
                HStack {
                    Spacer()
                    Menu {
                        Button("从压缩包安装…") { pickArchive() }
                        Button("重新扫描") { model.refreshRuntimes() }
                        Divider()
                        Button("打开 Runtimes 文件夹") { NSWorkspace.shared.open(model.paths.runtimesDir) }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .fixedSize()
                    .help("更多操作")
                    .accessibilityLabel("更多操作")
                }
            }

            Section {
                TextField("自定义 wine 路径", text: $model.settings.customWineBinary, prompt: Text("/path/to/bin/wine"))
                    .onSubmit { model.refreshRuntimes() }
            } footer: {
                Text("已经有别的 Wine 构建时填它的 wine 程序路径，按回车后出现在上面的列表里。")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        // 打开设置时光标不要自己跳进“自定义 wine 路径”。
        .onAppear { DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) } }
        .task(id: model.runtimes) {
            for runtime in model.runtimes where versions[runtime.id] == nil {
                versions[runtime.id] = await runtime.version() ?? "?"
            }
        }
    }

    private var hasRecommendedRuntime: Bool {
        model.runtimes.contains { $0.source == .managed && $0.rootDirectory.lastPathComponent == RuntimeInstaller.recommended.name }
    }

    private func label(for runtime: WineRuntime) -> String {
        let version = versions[runtime.id].map { " · \($0)" } ?? ""
        return runtime.displayName + version
    }

    private func pickArchive() {
        let panel = NSOpenPanel()
        panel.title = "选择 Wine 运行时压缩包（.tar.xz / .tar.gz / .zip）"
        panel.allowedContentTypes = [.archive, .gzip, .zip, UTType(filenameExtension: "xz") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.installRuntime(from: url)
    }
}

// MARK: - 字体

struct FontSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TextField("中日文字体替换为", text: $model.settings.cjkFont, prompt: Text("自动"))
            } footer: {
                Text("Windows 游戏里的 MS Gothic、SimSun 等字体会换成这里填的 macOS 字体。留空则按游戏区域选择：日文用 Hiragino Sans W3，中文用 Hiragino Sans GB W3。下次启动游戏时生效。")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .onAppear { DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) } }
    }
}

// MARK: - 翻译

struct TranslationSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                if model.settings.providers.isEmpty {
                    Text("还没有翻译服务，点右下角的 + 添加。").foregroundStyle(.secondary)
                }
                ForEach(model.settings.providers) { provider in
                    NavigationLink(value: provider.id) {
                        let active = provider.id == model.settings.activeProvider?.id
                        StatusRow(symbol: "character.bubble.fill", color: .purple, title: provider.name,
                                  status: active ? "当前使用 · \(provider.model)" : provider.model, ok: active) {
                            EmptyView()
                        }
                    }
                }
            } header: {
                Text("翻译服务")
            } footer: {
                HStack {
                    Spacer()
                    Menu {
                        ForEach(LLMProviderConfig.presets) { preset in
                            Button(preset.name) { add(preset) }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .fixedSize()
                    .help("从预设添加一个翻译服务")
                    .accessibilityLabel("添加翻译服务")
                }
            }
            Section("提示词（所有服务共用）") {
                TextField("目标语言", text: $model.settings.prompt.targetLanguage)
                Stepper("上文行数：\(model.settings.prompt.contextLines)", value: $model.settings.prompt.contextLines, in: 0...20)
                TextEditor(text: $model.settings.prompt.systemPrompt)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 80)
                Button("恢复默认提示词") { model.settings.prompt.systemPrompt = TranslationPromptConfig.defaultSystemPrompt }
            }
        }
        .formStyle(.grouped)
        .navigationDestination(for: UUID.self) { id in
            ProviderSettingsView(id: id)
        }
    }

    private func add(_ preset: LLMProviderConfig) {
        var config = preset
        config.id = UUID()
        model.settings.providers.append(config)
        if model.settings.activeProviderID == nil { model.settings.activeProviderID = config.id }
    }
}

/// 一个翻译服务的详细设置（从翻译页点进来）。
private struct ProviderSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var apiKey = ""
    @State private var confirmingRemoval = false
    @State private var testInput = "冬馬かずさは、ピアノが上手だ。"
    @State private var testOutput = ""
    @State private var testFailed = false
    @State private var testing = false

    var body: some View {
        @Bindable var model = model
        Form {
            if let index = model.settings.providers.firstIndex(where: { $0.id == id }) {
                editor($model.settings.providers[index])
            }
        }
        .formStyle(.grouped)
        .navigationTitle(model.settings.providers.first { $0.id == id }?.name ?? "翻译服务")
        .onAppear { apiKey = APIKeyStore.shared.apiKey(for: id) ?? "" }
        .onDisappear { saveKey() }
        .confirmationDialog("删除这个翻译服务？", isPresented: $confirmingRemoval) {
            Button("删除", role: .destructive) { remove() }
        } message: {
            Text("它的 API Key 也会一起删除。")
        }
    }

    @ViewBuilder
    private func editor(_ provider: Binding<LLMProviderConfig>) -> some View {
        Section {
            TextField("名称", text: provider.name)
            Picker("接口类型", selection: provider.style) {
                ForEach(LLMAPIStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            TextField("Base URL", text: provider.baseURL)
            TextField("模型", text: provider.model)
            SecureField("API Key", text: $apiKey)
                .onSubmit { saveKey() }
                // 停手 0.6 秒再保存，不要每个字都写一次。
                .task(id: apiKey) {
                    try? await Task.sleep(for: .milliseconds(600))
                    if !Task.isCancelled { saveKey() }
                }
        }
        Section {
            if provider.wrappedValue.style == .openAICompatible {
                LabeledContent("温度") {
                    HStack {
                        Toggle("自定义温度", isOn: Binding(
                            get: { provider.wrappedValue.temperature != nil },
                            set: { provider.wrappedValue.temperature = $0 ? 0.3 : nil }
                        )).labelsHidden()
                        if let t = provider.wrappedValue.temperature {
                            Slider(value: Binding(get: { t }, set: { provider.wrappedValue.temperature = $0 }), in: 0...1.5)
                            Text(t, format: .number.precision(.fractionLength(1))).monospacedDigit()
                        }
                    }
                }
            }
            Stepper("超时：\(Int(provider.wrappedValue.timeoutSeconds)) 秒", value: provider.timeoutSeconds, in: 5...300, step: 5)
        }
        Section("测试") {
            TextField("原文", text: $testInput)
            HStack {
                Button("测试翻译") { runTest(provider.wrappedValue) }
                    .disabled(testing || testInput.trimmingCharacters(in: .whitespaces).isEmpty)
                if testing { ProgressView().controlSize(.small) }
            }
            if testFailed {
                Label(testOutput, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).textSelection(.enabled)
            } else if !testOutput.isEmpty {
                Text(testOutput).textSelection(.enabled)
            }
        }
        Section {
            HStack {
                if model.settings.activeProvider?.id == id {
                    Label("翻译时正在使用这个服务", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                } else {
                    Button("设为当前使用") { model.settings.activeProviderID = id }
                }
                Spacer()
                Button("删除服务…", role: .destructive) { confirmingRemoval = true }
            }
        }
    }

    private func saveKey() {
        // 服务已经被删掉时不要把 Key 写回去。
        guard model.settings.providers.contains(where: { $0.id == id }) else { return }
        guard (APIKeyStore.shared.apiKey(for: id) ?? "") != apiKey else { return }
        APIKeyStore.shared.setAPIKey(apiKey, for: id)
        model.overlay.settingsDidChange()
    }

    private func remove() {
        model.settings.providers.removeAll { $0.id == id }
        if model.settings.activeProviderID == id { model.settings.activeProviderID = model.settings.providers.first?.id }
        APIKeyStore.shared.setAPIKey(nil, for: id)
        dismiss()
    }

    private func runTest(_ provider: LLMProviderConfig) {
        saveKey()
        let translator = LLMTranslator(provider: provider, prompt: model.settings.prompt, apiKey: APIKeyStore.shared.apiKey(for: id))
        testing = true
        testOutput = ""
        testFailed = false
        let input = testInput
        Task {
            defer { testing = false }
            do {
                testOutput = try await translator.translate(TranslationRequest(text: input))
            } catch {
                testOutput = error.localizedDescription
                testFailed = true
            }
        }
    }
}

private func copy(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}
