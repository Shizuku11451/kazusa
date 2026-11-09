// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import KazusaCore
import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var showInspector = true
    @State private var isDropTargeted = false

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 18)]

    var body: some View {
        @Bindable var model = model

        Group {
            if model.games.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                        ForEach(model.games) { game in
                            GameCard(game: game,
                                     cover: model.coverImages[game.id],
                                     isSelected: game.id == model.selectedGameID,
                                     isRunning: model.runningGameIDs.contains(game.id))
                                .onTapGesture { model.selectedGameID = game.id }
                                .simultaneousGesture(TapGesture(count: 2).onEnded { model.launch(game) })
                                .contextMenu {
                                    Button("启动") { model.launch(game) }
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
                    .padding(20)
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
        .navigationTitle("游戏库")
        .toolbar {
            ToolbarItemGroup {
                Button { model.presentImportPanel() } label: { Label("添加游戏", systemImage: "plus") }
                Button { model.overlay.show(game: model.selectedGame) } label: {
                    Label("翻译悬浮窗", systemImage: "character.bubble")
                }
                Button { showInspector.toggle() } label: { Label("详情", systemImage: "sidebar.right") }
            }
        }
        .inspector(isPresented: $showInspector) {
            Group {
                if let id = model.selectedGameID, let binding = model.binding(for: id) {
                    GameDetailView(game: binding)
                } else {
                    ContentUnavailableView("未选择游戏", systemImage: "gamecontroller", description: Text("在左侧选择一个游戏查看详情。"))
                }
            }
            .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
        .sheet(item: $model.coverSearch) { request in
            CoverSearchView(gameID: request.id)
        }
        .alert(item: $model.alert) { item in
            Alert(title: Text(item.title), message: Text(item.message))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(gradient)
                    .aspectRatio(3 / 4, contentMode: .fit)
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
                    .shadow(color: .black.opacity(cover == nil ? 0 : 0.18), radius: 4, y: 2)
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
    }

    /// 用标题算一个稳定的颜色，没有封面时也好区分。
    private var gradient: LinearGradient {
        let hash = game.title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let hue = Double(hash % 360) / 360
        return LinearGradient(
            colors: [Color(hue: hue, saturation: 0.55, brightness: 0.85), Color(hue: hue + 0.08, saturation: 0.7, brightness: 0.55)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
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
