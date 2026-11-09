// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import KazusaCore
import SwiftUI

struct GameDetailView: View {
    @Environment(AppModel.self) private var model
    @Binding var game: Game

    @State private var candidates: [String] = []
    @State private var detection: EngineDetection?
    @State private var argumentsText = ""
    @State private var glossaryText = ""
    @State private var isCoverDropTargeted = false
    @State private var isSynopsisExpanded = false

    var body: some View {
        Form {
            Section {
                coverSection
                TextField("标题", text: $game.title)
                HStack {
                    if model.runningGameIDs.contains(game.id) {
                        Button("停止", role: .destructive) { model.stop(game) }
                    } else {
                        Button("启动") { model.launch(game) }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.return, modifiers: .command)
                    }
                    Spacer()
                    Text(playTime).font(.caption).foregroundStyle(.secondary)
                }
            }

            infoSection

            Section("运行") {
                Picker("主程序", selection: $game.executable) {
                    ForEach(executableOptions, id: \.self) { Text($0).tag($0) }
                }
                Picker("区域（转区）", selection: localeBinding) {
                    ForEach(GameLocale.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                TextField("Wine 前缀", text: $game.prefixName)
                TextField("启动参数", text: $argumentsText)
                    .onSubmit(commitArguments)
                LabeledContent("引擎") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Picker("", selection: $game.engine) {
                            ForEach(EngineKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                        if let detection, !detection.evidence.isEmpty {
                            Text("依据：" + detection.evidence.prefix(3).joined(separator: "、"))
                                .font(.caption2).foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }

            Section("翻译") {
                Toggle("启动时打开翻译悬浮窗", isOn: $game.translation.enabled)
                VStack(alignment: .leading, spacing: 4) {
                    Text("术语表（每行一条：原文=译文）").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $glossaryText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 90)
                        .onChange(of: glossaryText) { commitGlossary() }
                }
            }

            Section("文件") {
                Button("在 Finder 中显示游戏") { NSWorkspace.shared.activateFileViewerSelecting([game.executableURL]) }
                Button("打开日志") { open(model.logFile(for: game)) }
                Button("打开 C 盘（前缀）") { open(model.prefixDriveC(for: game)) }
                Text(game.directory.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }

            Section {
                Button("从游戏库移除", role: .destructive) { model.remove(game) }
            }
        }
        .formStyle(.grouped)
        .task(id: game.id) {
            isSynopsisExpanded = false
            await reload()
        }
    }

    /// 封面预览：可以把图片拖到这里替换。
    private var coverSection: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let cover = model.coverImages[game.id] {
                    Image(nsImage: cover).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay { Image(systemName: "photo").font(.title).foregroundStyle(.secondary) }
                }
            }
            .frame(width: 96, height: 128)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                if isCoverDropTargeted {
                    RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                model.setCover(fromFile: url, for: game.id)
                return true
            } isTargeted: { isCoverDropTargeted = $0 }

            VStack(alignment: .leading, spacing: 6) {
                Text("封面").font(.headline)
                Button("搜索 VNDB…") { model.coverSearch = .init(id: game.id) }
                Button("选择图片…") { model.chooseCoverFile(for: game.id) }
                if model.coverImages[game.id] != nil {
                    Button("移除", role: .destructive) { model.removeCover(for: game.id) }
                }
                Text("也可以把图片拖到左边").font(.caption2).foregroundStyle(.secondary)
            }
            .buttonStyle(.link)
        }
    }

    /// VNDB 上的简介、品牌、发售日等。
    @ViewBuilder
    private var infoSection: some View {
        let isLoading = model.metadataLoading.contains(game.id)
        Section {
            if let m = game.metadata {
                if let title = m.chineseTitle, title != game.title { LabeledContent("中文名", value: title) }
                if let title = m.originalTitle, title != game.title { LabeledContent("原名", value: title) }
                if !m.developers.isEmpty { LabeledContent("品牌", value: m.developers.joined(separator: "、")) }
                if let released = m.releasedText { LabeledContent("发售", value: released) }
                if let length = m.lengthText { LabeledContent("游玩时长", value: length) }
                if let rating = m.ratingText { LabeledContent("VNDB 评分", value: rating) }
                if let synopsis = m.synopsis {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(synopsis)
                            .lineLimit(isSynopsisExpanded ? nil : 4)
                            .textSelection(.enabled)
                        Button(isSynopsisExpanded ? "收起" : "展开") { isSynopsisExpanded.toggle() }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            } else if isLoading {
                HStack { ProgressView().controlSize(.small); Text("正在从 VNDB 获取资料…").foregroundStyle(.secondary) }
            } else if game.vndbID != nil {
                Text("资料还没获取到（可能是没联网）。").foregroundStyle(.secondary)
            } else {
                Text("还没关联 VNDB 条目。可以按标题自动匹配，或者用“搜索 VNDB…”手动选（会同时换封面）。")
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("资料")
                Spacer()
                if let id = game.vndbID {
                    Link("VNDB \(id)", destination: URL(string: "https://vndb.org/\(id)")!)
                    Button("刷新") { model.fetchMetadata(for: game.id, silent: false) }.disabled(isLoading)
                    Button("解除关联") { model.unlinkVNDB(for: game.id) }
                } else {
                    Button("自动匹配") { Task { await model.matchMetadata(for: game.id) } }.disabled(isLoading)
                }
            }
            .buttonStyle(.link).font(.caption)
        }
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

    private var playTime: String {
        let minutes = Int(game.totalPlaySeconds / 60)
        let total = minutes < 60 ? "\(minutes) 分钟" : "\(minutes / 60) 小时 \(minutes % 60) 分"
        guard let last = game.lastPlayedAt else { return "还没玩过" }
        return "已玩 \(total) · 上次 \(last.formatted(.relative(presentation: .named)))"
    }

    private func reload() async {
        argumentsText = game.arguments.joined(separator: " ")
        glossaryText = game.translation.glossary
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
        let directory = game.directory
        let title = game.title
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

    private func open(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            model.alert = .init(title: "还不存在", message: "\(url.path)\n\n启动一次游戏后才会生成。")
        }
    }
}
