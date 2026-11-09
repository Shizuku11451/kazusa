// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import KazusaCore
import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var isDropTargeted = false

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 18)]

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            library
                .navigationDestination(item: $model.openedGameID) { id in
                    if let binding = model.binding(for: id) {
                        GameDetailView(game: binding)
                    }
                }
        }
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
        .sheet(item: $model.coverSearch) { request in
            CoverSearchView(gameID: request.id)
        }
        .sheet(item: $model.gameSettings) { request in
            if let binding = model.binding(for: request.id) {
                GameSettingsView(game: binding)
            }
        }
        .alert(item: $model.alert) { item in
            Alert(title: Text(item.title), message: Text(item.message))
        }
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
                                     isSelected: game.id == model.selectedGameID,
                                     isRunning: model.runningGameIDs.contains(game.id),
                                     onLaunch: { model.launch(game) })
                                .onTapGesture { model.open(game.id) }
                                .contextMenu {
                                    Button("启动") { model.launch(game) }
                                    Button("设置…") { model.gameSettings = .init(id: game.id) }
                                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([game.executableURL]) }
                                    Divider()
                                    Button("搜索封面…") { model.coverSearch = .init(id: game.id) }
                                    Button("选择封面图片…") { model.chooseCoverFile(for: game.id) }
                                    if model.coverImages[game.id] != nil {
                                        Button("移除封面") { model.removeCover(for: game.id) }
                                    }
                                    Divider()
                                    Button("从游戏库移除", role: .destructive) { model.remove(game) }
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
        .navigationTitle("游戏库")
        .toolbar {
            ToolbarItemGroup {
                Button { model.presentImportPanel() } label: { Label("添加游戏", systemImage: "plus") }
                Button { model.overlay.show(game: model.selectedGame) } label: {
                    Label("翻译悬浮窗", systemImage: "character.bubble")
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
    let isSelected: Bool
    let isRunning: Bool
    let onLaunch: () -> Void

    @State private var isHovered = false

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
                    .scaleEffect(isHovered ? 1.02 : 1)
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
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3)
            )

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
