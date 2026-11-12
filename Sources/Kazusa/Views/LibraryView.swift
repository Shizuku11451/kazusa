// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import KazusaCore
import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDropTargeted = false
    @State private var coverFlight = CoverFlight()

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 18)]

    var body: some View {
        @Bindable var model = model

        // 没用 navigationDestination：系统的跳转把详情页放在另一层，封面没法从卡片飞过去（macOS 也没有 .zoom 转场）。
        NavigationStack {
            ZStack {
                // 游戏库一直留着，返回时滚动位置不变。
                library
                    .allowsHitTesting(openedGame == nil)
                    .accessibilityHidden(openedGame != nil)
                if let binding = openedGame {
                    GameDetailView(game: binding)
                        .background(Color(nsColor: .windowBackgroundColor))
                        // 封面由最上层的飞行层负责，页面本身只需快速淡入淡出。
                        .transition(.opacity.animation(.easeOut(duration: 0.15)))
                        .zIndex(1)
                }
            }
            .coordinateSpace(.named(CoverFlight.space))
            .overlay(alignment: .topLeading) {
                CoverFlightLayer(flight: coverFlight) { id in
                    model.games.first { $0.id == id }.map { ($0.title, model.coverImages[id]) }
                }
            }
            .navigationTitle(openedGame?.wrappedValue.title ?? "游戏库")
        }
        // 减弱动态效果时只淡入淡出，封面不飞。
        .environment(\.coverFlight, reduceMotion ? nil : coverFlight)
        .onChange(of: model.openedGameID) { old, new in
            guard !reduceMotion else { return }
            if let new { coverFlight.open(new) } else if let old { coverFlight.close(old) }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : CoverFlight.animation, value: model.openedGameID)
        .overlay(alignment: .bottom) {
            if let message = model.busyMessage {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(message)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding()
            }
        }
        .sheet(isPresented: $model.showingOnboarding) { OnboardingView() }
        .sheet(item: $model.coverSearch) { request in
            CoverSearchView(gameID: request.id)
        }
        .sheet(item: $model.gameSettings) { request in
            if let binding = model.binding(for: request.id) {
                GameSettingsView(game: binding)
            }
        }
        .confirmationDialog("从游戏库移除“\(pendingRemoval?.title ?? "")”？",
                            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { model.confirmingRemoval = nil } }),
                            presenting: pendingRemoval) { game in
            Button("移除", role: .destructive) { model.remove(game) }
        } message: { _ in
            Text("自定义封面、翻译记录、术语表和游玩时长会一起删除。游戏文件、存档和存档备份不受影响。")
        }
        .confirmationDialog("停止“\(pendingStop?.title ?? "")”？",
                            isPresented: Binding(get: { pendingStop != nil }, set: { if !$0 { model.confirmingStop = nil } }),
                            presenting: pendingStop) { game in
            Button("停止", role: .destructive) { model.stop(game) }
        } message: { _ in
            Text("会直接结束游戏，没存档的进度会丢失。")
        }
        .alert(model.alert?.title ?? "", isPresented: alertShown, presenting: model.alert) { item in
            if let action = item.action {
                Button(action.title) { action.run() }
            }
            if let tab = item.settingsTab {
                Button("去设置") {
                    model.settingsTab = tab
                    openWindow(id: SettingsView.windowID)
                }
                Button("好", role: .cancel) {}
            } else {
                Button("好", role: .cancel) {}
            }
        } message: { item in
            Text(item.message)
        }
    }

    private var openedGame: Binding<Game>? { model.openedGameID.flatMap { model.binding(for: $0) } }

    private var pendingRemoval: Game? { model.confirmingRemoval.flatMap { r in model.games.first { $0.id == r.id } } }
    private var pendingStop: Game? { model.confirmingStop.flatMap { r in model.games.first { $0.id == r.id } } }

    private var alertShown: Binding<Bool> {
        Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })
    }

    private var library: some View {
        Group {
            if model.games.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                        ForEach(model.games) { game in
                            GameCard(game: game,
                                     cover: model.coverImages[game.id],
                                     isRunning: model.runningGameIDs.contains(game.id),
                                     isOpened: game.id == model.openedGameID,
                                     onLaunch: { model.launch(game) })
                                .activatable(game.title) { model.open(game.id) }
                                .contextMenu {
                                    Button("启动") { model.launch(game) }
                                    Button("游戏设置…") { model.gameSettings = .init(id: game.id) }
                                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([game.executableURL]) }
                                    Divider()
                                    Button("在 VNDB 上搜索封面…") { model.coverSearch = .init(id: game.id) }
                                    Button("选择封面图片…") { model.chooseCoverFile(for: game.id) }
                                    if model.coverImages[game.id] != nil {
                                        Button("移除封面") { model.removeCover(for: game.id) }
                                    }
                                    Divider()
                                    Button("从游戏库移除…", role: .destructive) { model.confirmingRemoval = .init(id: game.id) }
                                }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls { model.importGame(at: url) }
            return !urls.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .padding(8)
            }
        }
        .toolbar {
            if model.openedGameID == nil {
                ToolbarItemGroup {
                    Button { model.presentImportPanel() } label: { Label("添加游戏", systemImage: "plus") }
                        .help("添加游戏文件夹或 .exe（⌘O）")
                    Button { model.overlay.show(game: model.selectedGame) } label: {
                        Label("翻译悬浮窗", systemImage: "character.bubble")
                    }
                    .help("打开翻译悬浮窗（⇧⌘T）")
                    Button { openWindow(id: SettingsView.windowID) } label: { Label("设置", systemImage: "gearshape") }
                        .help("运行环境、翻译服务（LLM）等全局设置")
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("游戏库是空的", systemImage: "books.vertical")
        } description: {
            Text("把游戏文件夹或 .exe 拖到这里，或者点击“添加游戏”。\n汉化版和日文原版都可以。")
        } actions: {
            Button("添加游戏…") { model.presentImportPanel() }
                .buttonStyle(.borderedProminent)
        }
    }
}

struct GameCard: View {
    let game: Game
    let cover: NSImage?
    let isRunning: Bool
    /// 详情页打开着：封面在详情页上，卡片这里先藏起来。
    var isOpened = false
    let onLaunch: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.coverFlight) private var coverFlight

    private var isCoverAway: Bool { isOpened || coverFlight?.isFlying(game.id) == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.clear)
                    .aspectRatio(3 / 4, contentMode: .fit)
                    .overlay { if cover == nil { CoverGradient(title: game.title) } }
                    .overlay {
                        if let cover {
                            Image(nsImage: cover)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Text(String(game.title.prefix(1)))
                                .font(.system(size: 56, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .reportsCoverFrame { coverFlight?.card(game.id, movedTo: $0) }
                    // 封面在详情页上或正在飞时先藏起来；显隐不做动画，免得和飞着的那张叠出重影。
                    .opacity(isCoverAway ? 0 : 1)
                    .animation(nil, value: isCoverAway)
                    .overlay {
                        // 悬停时显示快速启动按钮，点卡片其他地方打开详情页。
                        if isHovered && !isRunning {
                            ZStack {
                                Color.black.opacity(0.25)
                                Button(action: onLaunch) {
                                    Image(systemName: "play.fill")
                                        .font(.title2)
                                        .foregroundStyle(.white)
                                        .frame(width: 52, height: 52)
                                        .background(Color.accentColor, in: Circle())
                                        .shadow(radius: 6)
                                }
                                .buttonStyle(.plain)
                                .help("启动")
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .shadow(color: .black.opacity(isHovered ? 0.3 : 0.15), radius: isHovered ? 10 : 4, y: isHovered ? 6 : 2)
                    .scaleEffect(isHovered && !reduceMotion ? 1.02 : 1)
                    .animation(.easeOut(duration: 0.15), value: isHovered)
                if isRunning {
                    Label("运行中", systemImage: "play.fill")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.green, in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }
            }

            Text(game.title)
                .font(.headline)
                .lineLimit(1)
                .help(game.title)
            HStack(spacing: 6) {
                Badge(text: game.engine.displayName)
                Badge(text: game.locale.displayName)
            }
        }
        // 每张卡片高度一致，同一行顶端对齐。
        .frame(maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

struct Badge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

extension View {
    /// 点一下，或键盘聚焦后按 Return / 空格执行，VoiceOver 当按钮读。
    /// 卡片里还套着别的按钮（快速启动、显示成人封面），所以没直接用 Button。
    func activatable(_ label: String, action: @escaping () -> Void) -> some View {
        onTapGesture(perform: action)
            .focusable(interactions: .activate)
            .onKeyPress(keys: [.return, .space]) { _ in
                action()
                return .handled
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}
