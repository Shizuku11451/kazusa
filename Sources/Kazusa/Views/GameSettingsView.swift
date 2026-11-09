// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import KazusaCore
import SwiftUI

/// 单个游戏的设置：标题、运行方式、区域、翻译等。从详情页的“设置”按钮打开。
struct GameSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @Binding var game: Game

    @State private var candidates: [String] = []
    @State private var detection: EngineDetection?
    @State private var argumentsText = ""
    @State private var glossaryText = ""
    @State private var translationCount = 0
    @State private var confirmingClear = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("标题", text: $game.title)
                }

                Section("运行") {
                    Picker("运行方式", selection: $game.backend) {
                        Text("自动（\(backendName(automaticBackend))）").tag(GameBackend?.none)
                        Text("Wine").tag(GameBackend?.some(.wine))
                        if let native = NativeEngines.name(for: game.engine) {
                            Text("原生（\(native)）").tag(GameBackend?.some(.native))
                        }
                    }
                    if let native = NativeEngines.name(for: game.engine), let reason = model.nativeUnsupported[game.id] {
                        Text("\(reason)，自动模式下用 Wine。也可以手动选“原生（\(native)）”试试。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if isWine {
                        Picker("主程序", selection: $game.executable) {
                            ForEach(executableOptions, id: \.self) { Text($0.isEmpty ? "（无）" : $0).tag($0) }
                        }
                    }
                    Picker(isWine ? "区域（转区）" : "区域（脚本编码）", selection: localeBinding) {
                        ForEach(GameLocale.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    if isWine {
                        Toggle(isOn: $game.usesExclusivePrefix) {
                            Text("使用独立前缀")
                            Text(game.usesExclusivePrefix
                                 ? "这个游戏有自己的 Wine 环境（\(game.prefixName)），装的东西、改的设置不影响别的游戏。"
                                 : "现在和同区域的游戏共用“\(game.prefixName)”。打开后从它复制一份给这个游戏单独用，不占额外空间。存在前缀里的存档不会跟着搬过去。")
                        }
                    }
                    TextField("启动参数", text: $argumentsText)
                    LabeledContent("引擎") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Picker("", selection: $game.engine) {
                                ForEach(EngineKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            if let detection, !detection.evidence.isEmpty {
                                Text("依据：" + detection.evidence.prefix(3).joined(separator: "、"))
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }
                }

                Section("翻译") {
                    LabeledContent("翻译服务") {
                        HStack {
                            if let provider = model.settings.activeProvider {
                                Text("\(provider.name) · \(provider.model)").foregroundStyle(.secondary)
                            } else {
                                Text("未配置").foregroundStyle(.orange)
                            }
                            Button(model.settings.activeProvider == nil ? "去配置…" : "更改…") {
                                model.settingsTab = .translation
                                openSettings()
                            }
                        }
                    }
                    Toggle("启动时打开翻译悬浮窗", isOn: $game.translation.enabled)
                    if isWine {
                        Toggle(isOn: $game.translation.usesTextHook) {
                            Text("用文本钩子读取游戏文本")
                            Text("直接从游戏进程读出台词，比截图识别准确、不用对准文本框。个别游戏钩不到时关掉，改用 OCR。")
                        }
                        .disabled(!game.translation.enabled)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("术语表（每行一条：原文=译文）").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $glossaryText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 110)
                    }
                    LabeledContent {
                        Button("清除…") { confirmingClear = true }
                            .disabled(translationCount == 0)
                    } label: {
                        Text("翻译记录")
                        Text(translationCount == 0
                             ? "还没有。翻过的句子会记下来，再遇到时直接用，不再调用翻译服务。"
                             : "已记下 \(translationCount) 句，再遇到时直接用。改了术语表想重新翻译时可以清除。")
                    }
                }

                Section("位置") {
                    LabeledContent("游戏目录") {
                        Text(game.directory.path).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                    }
                    LabeledContent("存档") {
                        if let locations = game.saveLocations, !locations.isEmpty {
                            VStack(alignment: .trailing, spacing: 2) {
                                ForEach(locations, id: \.self) { Text($0.displayName) }
                            }
                            .textSelection(.enabled)
                        } else {
                            Text("还没找到。存个档再退出游戏，会自动找到并备份。").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 600)
        .onChange(of: argumentsText) { commitArguments() }
        .onChange(of: glossaryText) { commitGlossary() }
        .onChange(of: game.engine) {
            if game.backend == .native && !NativeEngines.supports(game.engine) { game.backend = nil }
            model.refreshNativeSupport(for: game)
        }
        .task(id: game.id) { await reload() }
        .confirmationDialog("清除“\(game.title)”的翻译记录？", isPresented: $confirmingClear) {
            Button("清除", role: .destructive) {
                model.clearTranslations(for: game.id)
                translationCount = 0
            }
        } message: {
            Text("之后遇到同样的句子会重新调用翻译服务。")
        }
    }

    private var isWine: Bool { model.backend(for: game) == .wine }

    private var automaticBackend: GameBackend {
        var copy = game
        copy.backend = nil
        return model.backend(for: copy)
    }

    private func backendName(_ backend: GameBackend) -> String {
        backend == .native ? NativeEngines.name(for: game.engine) ?? "原生" : "Wine"
    }

    private var executableOptions: [String] {
        candidates.contains(game.executable) ? candidates : [game.executable] + candidates
    }

    /// 改区域时，如果前缀还是默认的，就跟着换成对应区域的默认前缀。
    private var localeBinding: Binding<GameLocale> {
        Binding(
            get: { game.locale },
            set: { newValue in
                if game.prefixName == game.locale.defaultPrefixName {
                    game.prefixName = newValue.defaultPrefixName
                }
                game.locale = newValue
            }
        )
    }

    private func reload() async {
        argumentsText = game.arguments.joined(separator: " ")
        glossaryText = game.translation.glossary
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
        let directory = game.directory
        let title = game.title
        let store = model.paths.translationStore(for: game.id)
        let language = model.settings.prompt.targetLanguage
        translationCount = await Task.detached { Set(store.load(language: language).map(\.source)).count }.value
        let result = await Task.detached {
            let paths = DirectoryScanner.relativePaths(in: directory, maxDepth: 3, maxEntries: 20_000)
            return (GameInspector.rankExecutables(paths: paths, directoryName: title, directory: directory),
                    EngineDetector.detect(relativePaths: paths))
        }.value
        candidates = result.0
        detection = result.1
    }

    private func commitArguments() {
        let args = argumentsText.split(separator: " ").map(String.init)
        if args != game.arguments { game.arguments = args }
    }

    private func commitGlossary() {
        var glossary: [String: String] = [:]
        for line in glossaryText.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[0].isEmpty { glossary[parts[0]] = parts[1] }
        }
        if glossary != game.translation.glossary { game.translation.glossary = glossary }
    }
}
