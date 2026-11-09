// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import KazusaCore
import SwiftUI

/// 在 VNDB 上按标题搜索，点一个结果把它的封面设为游戏封面。
struct CoverSearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let gameID: UUID

    @State private var query = ""
    @State private var results: [VNDBEntry] = []
    @State private var isSearching = false
    @State private var applyingID: String?
    @State private var errorMessage: String?
    /// 用户点了“显示”的成人 / 血腥封面。
    @State private var revealed: Set<String> = []

    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 160), spacing: 14)]

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("游戏标题（日文原名最准）", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search(query) } }
                Button("搜索") { Task { await search(query) } }
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
            }

            ZStack {
                if isSearching {
                    ProgressView("正在搜索 VNDB…")
                } else if let errorMessage {
                    ContentUnavailableView("搜索失败", systemImage: "wifi.exclamationmark", description: Text(errorMessage))
                } else if results.isEmpty {
                    ContentUnavailableView("没有结果", systemImage: "magnifyingglass",
                                           description: Text("换个写法试试，比如日文原名或罗马音。"))
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                            ForEach(results) { entry in resultCell(entry) }
                        }
                        .padding(2)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Text("数据来自 VNDB（vndb.org）。只会把搜索词发送给它。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 620, height: 520)
        .task { await start() }
    }

    @ViewBuilder
    private func resultCell(_ entry: VNDBEntry) -> some View {
        let hidden = !entry.hasSafeImage && !revealed.contains(entry.id)
        VStack(alignment: .leading, spacing: 4) {
            Color.secondary.opacity(0.15)
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay {
                    if let url = entry.imageURL {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill()
                            } else if phase.error != nil {
                                Image(systemName: "photo").foregroundStyle(.secondary)
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                        .blur(radius: hidden ? 24 : 0)
                    } else {
                        Text("无封面").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .overlay {
                    if hidden && entry.imageURL != nil {
                        Button("可能含成人内容\n点击显示") { revealed.insert(entry.id) }
                            .buttonStyle(.plain)
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                            .padding(6)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .overlay {
                    if applyingID == entry.id { ProgressView() }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .onTapGesture { if !hidden { Task { await apply(entry) } } }
            Text(entry.displayTitle).font(.caption).lineLimit(2)
            Text([entry.released, entry.id].compactMap { $0 }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .disabled(entry.imageURL == nil || applyingID != nil)
        .help(entry.title)
    }

    private func start() async {
        guard let game = model.games.first(where: { $0.id == gameID }) else { return }
        let queries = VNDB.searchQueries(for: game.title)
        query = queries.last ?? game.title
        // 依次尝试，用第一个有结果的搜索词。
        for q in queries {
            await search(q)
            if !results.isEmpty || errorMessage != nil {
                query = q
                return
            }
        }
    }

    private func search(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }
        do {
            results = try await VNDB.search(text, results: 24)
        } catch {
            results = []
            errorMessage = error.localizedDescription
        }
    }

    private func apply(_ entry: VNDBEntry) async {
        applyingID = entry.id
        defer { applyingID = nil }
        do {
            try await model.applyCover(from: entry, to: gameID)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
