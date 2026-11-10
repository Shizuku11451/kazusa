// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import KazusaCore
import SwiftUI

/// 游戏详情页：大封面、资料、启动按钮和简介。运行和翻译的设置放在“设置”弹窗里。
struct GameDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.coverFlight) private var coverFlight
    @Binding var game: Game

    @State private var isCoverDropTargeted = false
    @State private var restoreCandidate: SaveBackups.Backup?
    @State private var isSynopsisExpanded = false
    @State private var showsOriginalSynopsis = false
    @State private var viewingScreenshot: GameMetadata.Screenshot?

    private var cover: NSImage? { model.coverImages[game.id] }
    private var isRunning: Bool { model.runningGameIDs.contains(game.id) }
    private var isLoadingMetadata: Bool { model.metadataLoading.contains(game.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                VStack(alignment: .leading, spacing: 28) {
                    stats
                    savesSection
                    aboutSection
                    screenshotsSection
                    charactersSection
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .frame(maxWidth: 900, alignment: .leading)
            }
        }
        .ignoresSafeArea(edges: .top)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.openedGameID = nil } label: { Label("返回", systemImage: "chevron.left") }
                    .keyboardShortcut("[", modifiers: .command)
                    .help("返回游戏库（⌘[）")
            }
            ToolbarItem { moreMenu }
        }
        // Esc 也能返回。用快捷键而不是 onExitCommand：后者要焦点在页面里，刚点完卡片时焦点常常不在。
        .background {
            Button("返回") { model.openedGameID = nil }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .task(id: game.id) {
            isSynopsisExpanded = false
            showsOriginalSynopsis = false
        }
        .sheet(item: $viewingScreenshot) { shot in
            ScreenshotViewer(screenshots: game.metadata?.screenshots ?? [shot], current: shot)
        }
        .confirmationDialog(
            "用 \(restoreCandidate?.date.formatted(date: .abbreviated, time: .shortened) ?? "") 的备份替换现在的存档？",
            isPresented: Binding(get: { restoreCandidate != nil }, set: { if !$0 { restoreCandidate = nil } }),
            presenting: restoreCandidate
        ) { backup in
            Button("恢复", role: .destructive) { model.restoreSaves(backup, for: game) }
        } message: { _ in
            Text("现在的存档会先自动备份一份（标着“恢复前”）。")
        }
    }

    // MARK: - 顶部

    private var hero: some View {
        HStack(alignment: .bottom, spacing: 28) {
            coverView
            VStack(alignment: .leading, spacing: 10) {
                if let subtitle {
                    Text(subtitle).font(.title3).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(game.title)
                    .font(.system(size: 30, weight: .bold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                if let byline {
                    Text(byline).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    // 认不出引擎时不显示，“未知”放在最显眼的地方像是出错了。
                    if game.engine != .unknown { Badge(text: game.engine.displayName) }
                    Badge(text: game.locale.displayName)
                    Badge(text: backendText)
                }
                HStack(spacing: 10) {
                    if isRunning {
                        Button(role: .destructive) { model.confirmingStop = .init(id: game.id) } label: {
                            Label("停止", systemImage: "stop.fill").frame(minWidth: 88)
                        }
                        .controlSize(.extraLarge)
                    } else {
                        Button { model.launch(game) } label: {
                            Label("启动", systemImage: "play.fill").frame(minWidth: 88)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.extraLarge)
                    }
                    Button { model.gameSettings = .init(id: game.id) } label: {
                        Label("游戏设置", systemImage: "slider.horizontal.3")
                    }
                    .controlSize(.extraLarge)
                }
                .padding(.top, 6)
            }
            .padding(.bottom, 4)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .padding(.top, 72)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { backdrop }
    }

    /// 封面模糊后铺在顶部，底部渐隐到窗口背景。
    private var backdrop: some View {
        ZStack {
            if let cover {
                Image(nsImage: cover)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 50)
                    .opacity(0.55)
            } else {
                CoverGradient(title: game.title).opacity(0.35)
            }
            LinearGradient(colors: [.clear, Color(nsColor: .windowBackgroundColor)], startPoint: .top, endPoint: .bottom)
        }
        .clipped()
    }

    /// 封面：可以把图片拖上来替换。
    private var coverView: some View {
        // Color.clear 定出大小，图片填满后才能被圆角正确裁掉。
        Color.clear.overlay {
            if let cover {
                Image(nsImage: cover).resizable().scaledToFill()
            } else {
                CoverGradient(title: game.title)
                    .overlay {
                        Text(String(game.title.prefix(1)))
                            .font(.system(size: 64, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                    }
            }
        }
        .frame(width: 180, height: 240)
        .clipShape(RoundedRectangle(cornerRadius: CoverFlight.detailRadius))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
        .reportsCoverFrame { coverFlight?.detail(game.id, movedTo: $0) }
        // 飞着的那张落地前先藏起来。
        .opacity(coverFlight?.isFlying(game.id) == true ? 0 : 1)
        .overlay {
            if isCoverDropTargeted {
                RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 3)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.setCover(fromFile: url, for: game.id)
            return true
        } isTargeted: { isCoverDropTargeted = $0 }
        .contextMenu { coverMenu }
        .help("把图片拖到这里可以替换封面")
    }

    /// 标题上方的小字：VNDB 上的原名或中文名，和标题一样时不显示。
    private var subtitle: String? {
        guard let m = game.metadata else { return nil }
        return [m.originalTitle, m.chineseTitle].compactMap { $0 }.first { $0 != game.title }
    }

    private var byline: String? {
        guard let m = game.metadata else { return nil }
        let parts = [m.developers.isEmpty ? nil : m.developers.joined(separator: "、"), m.releasedText].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var backendText: String {
        model.backend(for: game) == .native ? NativeEngines.name(for: game.engine) ?? "原生" : "Wine"
    }

    // MARK: - 数据

    private var stats: some View {
        HStack(spacing: 0) {
            Stat(title: "VNDB 评分", value: game.metadata?.ratingText ?? "—")
            Divider().frame(height: 32)
            Stat(title: progressTitle, value: playTime, progress: playProgress)
            Divider().frame(height: 32)
            Stat(title: "上次游玩", value: game.lastPlayedAt?.formatted(.relative(presentation: .named)) ?? "还没玩过")
        }
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private var progressTitle: String {
        game.metadata?.lengthText.map { "已玩 / 平均通关\($0)" } ?? "已玩"
    }

    /// 已玩时长占 VNDB 平均通关时长的比例；没有通关时长时不显示进度条。
    private var playProgress: Double? {
        guard let minutes = game.metadata?.lengthMinutes, minutes > 0 else { return nil }
        return min(game.totalPlaySeconds / 60 / Double(minutes), 1)
    }

    private var playTime: String {
        let minutes = Int(game.totalPlaySeconds / 60)
        return minutes < 60 ? "\(minutes) 分钟" : "\(minutes / 60) 小时 \(minutes % 60) 分"
    }

    // MARK: - 存档

    private var savesSection: some View {
        let busy = model.savesBusy.contains(game.id)
        let backups = model.saveBackups(for: game)
        return HStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.timemachine")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("存档").font(.headline)
                Group {
                    if busy {
                        Text("正在处理存档…")
                    } else if let last = backups.first {
                        Text("上次备份 \(last.date.formatted(.relative(presentation: .named)))（\(last.kind.displayName)）· 共 \(backups.count) 份")
                    } else if (game.saveLocations ?? []).isEmpty {
                        Text("还没找到存档。在游戏里存一次档再退出，Kazusa 会自动找到并备份。")
                    } else {
                        Text("还没有备份。")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if busy { ProgressView().controlSize(.small) }
            Button("立即备份") { model.backUpSaves(for: game) }
                .disabled(busy || (game.saveLocations ?? []).isEmpty)
            Menu("恢复") {
                ForEach(backups.prefix(30)) { backup in
                    Button("\(backup.date.formatted(date: .abbreviated, time: .shortened))（\(backup.kind.displayName)）") {
                        restoreCandidate = backup
                    }
                }
            }
            .fixedSize()
            .disabled(busy || backups.isEmpty)
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 截图和角色

    // shortcut: 图片走 AsyncImage + URLSession 默认缓存，离线时可能显示不出来；要离线看再存到本地。
    @ViewBuilder
    private var screenshotsSection: some View {
        if let shots = game.metadata?.screenshots, !shots.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("截图").font(.title2.bold())
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 10) {
                        ForEach(shots) { shot in
                            Button { viewingScreenshot = shot } label: {
                                AsyncImage(url: shot.thumbnail) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    Rectangle().fill(.quaternary)
                                }
                                .frame(width: 214, height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("截图")
                            .help("点击查看大图")
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    @ViewBuilder
    private var charactersSection: some View {
        if let characters = game.metadata?.characters, !characters.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("角色").font(.title2.bold())
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(characters) { c in
                            Link(destination: URL(string: "https://vndb.org/\(c.id)")!) {
                                VStack(spacing: 6) {
                                    AsyncImage(url: c.imageURL) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: {
                                        Circle().fill(.quaternary).overlay {
                                            Image(systemName: "person.fill").foregroundStyle(.secondary)
                                        }
                                    }
                                    // VNDB 角色图是半身立绘，从顶上裁才露出脸。
                                    .frame(width: 72, height: 72, alignment: .top)
                                    .clipShape(Circle())
                                    Text(c.original ?? c.name).font(.callout).lineLimit(1)
                                    if c.isProtagonist {
                                        Text("主角").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: 88)
                            }
                            .buttonStyle(.plain)
                            .help("\(c.name)：在 VNDB 上查看")
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    // MARK: - 简介

    @ViewBuilder
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("简介").font(.title2.bold())
                Spacer()
                if let id = game.vndbID {
                    Link("在 VNDB 上查看", destination: URL(string: "https://vndb.org/\(id)")!).font(.callout)
                }
            }
            if let tags = game.metadata?.tags, !tags.isEmpty {
                Text(tags.joined(separator: "  ·  ")).font(.callout).foregroundStyle(.secondary)
            }
            if let synopsis = game.metadata?.synopsis {
                synopsisView(original: synopsis, translation: game.metadata?.synopsisTranslation)
            } else if isLoadingMetadata {
                HStack { ProgressView().controlSize(.small); Text("正在从 VNDB 获取资料…").foregroundStyle(.secondary) }
            } else if game.metadata != nil {
                Text("VNDB 上没有这个游戏的简介。").foregroundStyle(.secondary)
            } else if game.vndbID != nil {
                HStack {
                    Text("资料还没获取到（可能是没联网）。").foregroundStyle(.secondary)
                    Button("重试") { model.fetchMetadata(for: game.id, silent: false) }
                }
            } else {
                HStack {
                    Text("还没关联 VNDB 条目。").foregroundStyle(.secondary)
                    Button("按标题匹配") { Task { await model.matchMetadata(for: game.id) } }
                    Button("搜索 VNDB…") { model.coverSearch = .init(id: game.id) }
                }
            }
        }
    }

    /// 有译文时默认显示译文；翻译中显示流式收到的部分。
    private func synopsisView(original: String, translation: String?) -> some View {
        let partial = model.synopsisTranslating[game.id]
        let isTranslating = partial != nil
        let shown: String
        if let partial {
            shown = partial.isEmpty ? original : partial
        } else if let translation, !showsOriginalSynopsis {
            shown = translation
        } else {
            shown = original
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text(shown)
                .font(.body)
                .lineSpacing(4)
                .lineLimit(isSynopsisExpanded || isTranslating ? nil : 6)
                .textSelection(.enabled)
                .foregroundStyle(partial?.isEmpty == true ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 14) {
                if isTranslating {
                    ProgressView().controlSize(.mini)
                    Text("正在翻译…").foregroundStyle(.secondary)
                } else {
                    Button(isSynopsisExpanded ? "收起" : "展开全文") { isSynopsisExpanded.toggle() }
                    if translation != nil {
                        Button(showsOriginalSynopsis ? "显示译文" : "显示原文") { showsOriginalSynopsis.toggle() }
                        Button("重新翻译") {
                            showsOriginalSynopsis = false
                            model.translateSynopsis(for: game.id)
                        }
                    } else {
                        Button("翻译成中文") {
                            showsOriginalSynopsis = false
                            model.translateSynopsis(for: game.id)
                        }
                    }
                }
            }
            .buttonStyle(.link)
            .font(.callout)
        }
    }

    // MARK: - 菜单

    @ViewBuilder
    private var coverMenu: some View {
        Button("在 VNDB 上搜索封面…") { model.coverSearch = .init(id: game.id) }
        Button("选择封面图片…") { model.chooseCoverFile(for: game.id) }
        if cover != nil {
            Button("移除封面") { model.removeCover(for: game.id) }
        }
    }

    private var moreMenu: some View {
        Menu {
            Section("封面") { coverMenu }
            Section("VNDB 资料") {
                if game.vndbID != nil {
                    Button("刷新资料") { model.fetchMetadata(for: game.id, silent: false) }.disabled(isLoadingMetadata)
                    Button("解除关联") { model.unlinkVNDB(for: game.id) }
                } else {
                    Button("按标题匹配") { Task { await model.matchMetadata(for: game.id) } }.disabled(isLoadingMetadata)
                }
            }
            Section {
                Button("打开翻译悬浮窗") { model.overlay.show(game: game) }
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([game.executableURL]) }
                Button("打开日志") { open(model.logFile(for: game), name: "日志") }
                if model.backend(for: game) == .wine {
                    Button("打开 C 盘（前缀）") { open(model.prefixDriveC(for: game), name: "前缀") }
                }
            }
            Section("存档") { Button("打开备份文件夹") { model.openBackupsFolder(for: game) } }
            Section {
                Button("从游戏库移除…", role: .destructive) { model.confirmingRemoval = .init(id: game.id) }
            }
        } label: {
            Label("更多", systemImage: "ellipsis.circle")
        }
        .help("封面、VNDB 资料、存档备份等操作")
    }

    private func open(_ url: URL, name: String) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            model.alert = .init(title: "\(name)还没生成", message: "\(url.path)\n\n启动一次游戏后才会生成。")
        }
    }
}

private struct Stat: View {
    let title: String
    let value: String
    var progress: Double?

    var body: some View {
        VStack(spacing: 4) {
            Text(value).font(.title3.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            if let progress {
                ProgressView(value: progress).frame(maxWidth: 140).controlSize(.small)
            }
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 看大图：左右方向键切换，Esc 或点一下关闭。
private struct ScreenshotViewer: View {
    let screenshots: [GameMetadata.Screenshot]
    @State var current: GameMetadata.Screenshot
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AsyncImage(url: current.url) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            AsyncImage(url: current.thumbnail) { $0.resizable().scaledToFit() } placeholder: { ProgressView() }
        }
        .frame(minWidth: 800, minHeight: 450)
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
        .onExitCommand { dismiss() }
    }

    private func step(_ delta: Int) -> KeyPress.Result {
        guard let i = screenshots.firstIndex(of: current) else { return .ignored }
        current = screenshots[(i + delta + screenshots.count) % screenshots.count]
        return .handled
    }
}

/// 没有封面时用标题算一个稳定的渐变色，方便区分。
struct CoverGradient: View {
    let title: String

    var body: some View {
        let hash = title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let hue = Double(hash % 360) / 360
        LinearGradient(
            colors: [Color(hue: hue, saturation: 0.55, brightness: 0.85), Color(hue: hue + 0.08, saturation: 0.7, brightness: 0.55)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}
