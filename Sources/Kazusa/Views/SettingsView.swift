// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import KazusaCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            RuntimeSettingsView()
                .tabItem { Label("运行环境", systemImage: "cpu") }
                .tag(AppModel.SettingsTab.runtime)
            TranslationSettingsView()
                .tabItem { Label("翻译", systemImage: "character.bubble") }
                .tag(AppModel.SettingsTab.translation)
        }
        .frame(width: 640, height: 520)
    }
}

// MARK: - 运行环境

struct RuntimeSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var versions: [String: String] = [:]

    var body: some View {
        @Bindable var model = model

        Form {
            Section("系统") {
                if SystemCheck.isAppleSilicon {
                    LabeledContent("Rosetta 2") {
                        if SystemCheck.isRosettaInstalled {
                            Label("已安装", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Label("未安装", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                    if !SystemCheck.isRosettaInstalled {
                        HStack {
                            Text(SystemCheck.rosettaInstallCommand)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            Button("复制命令") { copy(SystemCheck.rosettaInstallCommand) }
                        }
                    }
                }
                LabeledContent("屏幕录制权限（OCR 用）") {
                    if ScreenTextCapture.hasPermission {
                        Label("已授权", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("请求授权") { ScreenTextCapture.requestPermission() }
                    }
                }
            }

            Section("Wine 运行时") {
                if model.runtimes.isEmpty {
                    Text("没有找到 Wine。可以安装 Wine 的 macOS 构建（例如 Homebrew 的 wine-stable，或 Gcenx 的 wine-crossover 构建），或者在下面导入一个压缩包。")
                        .font(.callout).foregroundStyle(.secondary)
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
                TextField("自定义 wine 路径", text: $model.settings.customWineBinary, prompt: Text("/path/to/bin/wine"))
                    .onSubmit { model.refreshRuntimes() }
                HStack {
                    Button("从压缩包安装…") { pickArchive() }
                    Button("重新扫描") { model.refreshRuntimes() }
                    Spacer()
                    Button("打开 Runtimes 文件夹") { NSWorkspace.shared.open(model.paths.runtimesDir) }
                }
            }

            Section {
                TextField("中日文字体替换为", text: $model.settings.cjkFont, prompt: Text("自动"))
            } header: {
                Text("字体")
            } footer: {
                Text("Windows 游戏里的 MS Gothic、SimSun 等字体会换成这里填的 macOS 字体。留空则按游戏区域选择：日文用 Hiragino Sans W3，中文用 Hiragino Sans GB W3。下次启动游戏时生效。")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
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

// MARK: - 翻译

struct TranslationSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?
    @State private var apiKey = ""
    @State private var testInput = "冬馬かずさは、ピアノが上手だ。"
    @State private var testOutput = ""
    @State private var testFailed = false
    @State private var testing = false

    var body: some View {
        @Bindable var model = model

        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                List(selection: $selection) {
                    ForEach(model.settings.providers) { provider in
                        HStack {
                            Text(provider.name)
                            Spacer()
                            if provider.id == model.settings.activeProvider?.id {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                                    .help("当前使用")
                                    .accessibilityLabel("当前使用")
                            }
                        }
                        .tag(provider.id)
                    }
                }
                .overlay {
                    if model.settings.providers.isEmpty {
                        Text("还没有翻译服务\n点下面的 + 添加").multilineTextAlignment(.center)
                            .font(.callout).foregroundStyle(.secondary).padding()
                    }
                }
                HStack {
                    Menu {
                        ForEach(LLMProviderConfig.presets) { preset in
                            Button(preset.name) { add(preset) }
                        }
                    } label: { Label("添加翻译服务", systemImage: "plus").labelStyle(.iconOnly) }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("从预设添加一个翻译服务")
                    Button { removeSelected() } label: { Label("删除翻译服务", systemImage: "minus").labelStyle(.iconOnly) }
                        .buttonStyle(.borderless)
                        .help("删除选中的翻译服务和它的 API Key")
                        .disabled(selection == nil)
                    Spacer()
                }
                .padding(6)
            }
            .frame(minWidth: 160, maxWidth: 200)

            Form {
                if let index = model.settings.providers.firstIndex(where: { $0.id == selection }) {
                    providerEditor($model.settings.providers[index])
                } else {
                    Section {
                        Text(model.settings.providers.isEmpty ? "先在左边点 + 添加一个翻译服务" : "在左边选一个翻译服务来编辑")
                            .foregroundStyle(.secondary)
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
                Section("测试") {
                    TextField("原文", text: $testInput)
                    HStack {
                        Button("测试翻译") { runTest() }
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
            }
            .formStyle(.grouped)
        }
        .onAppear { selection = selection ?? model.settings.activeProvider?.id }
        .onChange(of: selection, initial: true) { old, new in
            // 第一次调用时输入框还是空的，不能拿它去覆盖钥匙串。
            if old != new { saveKey(for: old) }
            loadKey()
        }
        .onDisappear { saveKey(for: selection) }
    }

    @ViewBuilder
    private func providerEditor(_ provider: Binding<LLMProviderConfig>) -> some View {
        Section("服务") {
            TextField("名称", text: provider.name)
            Picker("接口类型", selection: provider.style) {
                ForEach(LLMAPIStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            TextField("Base URL", text: provider.baseURL)
            TextField("模型", text: provider.model)
            SecureField("API Key（保存在钥匙串）", text: $apiKey)
                .onSubmit { saveKey(for: selection) }
                // 停手 0.6 秒再写钥匙串，不要每个字都写一次。
                .task(id: apiKey) {
                    try? await Task.sleep(for: .milliseconds(600))
                    if !Task.isCancelled { saveKey(for: selection) }
                }
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
            if model.settings.activeProvider?.id == provider.wrappedValue.id {
                Label("翻译时正在使用这个服务", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
            } else {
                Button("设为当前使用") { model.settings.activeProviderID = provider.wrappedValue.id }
            }
        }
    }

    private func add(_ preset: LLMProviderConfig) {
        var config = preset
        config.id = UUID()
        model.settings.providers.append(config)
        if model.settings.activeProviderID == nil { model.settings.activeProviderID = config.id }
        selection = config.id
    }

    private func removeSelected() {
        guard let id = selection else { return }
        model.settings.providers.removeAll { $0.id == id }
        if model.settings.activeProviderID == id { model.settings.activeProviderID = model.settings.providers.first?.id }
        Keychain.setAPIKey(nil, for: id)
        selection = model.settings.providers.first?.id
    }

    private func loadKey() {
        apiKey = selection.flatMap { Keychain.apiKey(for: $0) } ?? ""
    }

    private func saveKey(for id: UUID?) {
        // 服务已经被删掉时不要把 Key 写回去。
        guard let id, model.settings.providers.contains(where: { $0.id == id }) else { return }
        let stored = Keychain.apiKey(for: id) ?? ""
        guard stored != apiKey else { return }
        Keychain.setAPIKey(apiKey, for: id)
        model.overlay.settingsDidChange()
    }

    private func runTest() {
        saveKey(for: selection)
        guard let provider = model.settings.providers.first(where: { $0.id == selection }) ?? model.settings.activeProvider else { return }
        let translator = LLMTranslator(provider: provider, prompt: model.settings.prompt, apiKey: Keychain.apiKey(for: provider.id))
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
