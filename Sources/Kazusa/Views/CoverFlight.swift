// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import SwiftUI

/// 封面“一镜到底”：卡片和详情页各自报告封面在哪，切换页面时在最上层画一张不透明的封面
/// 从一处飞到另一处，落地后再露出真正的封面。
/// 没用 matchedGeometryEffect：封面要放在详情页里，页面淡入时它也跟着半透明，看起来就不像在飞了。
@Observable @MainActor
final class CoverFlight {
    struct Flight {
        let id: UUID
        let token: Int
        let opening: Bool
        var rect: CGRect
        var radius: CGFloat
        var started = false
    }

    static let space = "coverFlight"
    static let animation = Animation.spring(duration: 0.45, bounce: 0.12)
    static let cardRadius: CGFloat = 10
    static let detailRadius: CGFloat = 12

    private(set) var flight: Flight?
    @ObservationIgnored private var cardFrames: [UUID: CGRect] = [:]
    @ObservationIgnored private var detailFrames: [UUID: CGRect] = [:]
    @ObservationIgnored private var layerShown = false
    @ObservationIgnored private var nextToken = 0

    func isFlying(_ id: UUID) -> Bool { flight?.id == id }

    func card(_ id: UUID, movedTo rect: CGRect) { cardFrames[id] = rect }

    func detail(_ id: UUID, movedTo rect: CGRect) {
        detailFrames[id] = rect
        if flight?.id == id { launchIfReady() }
    }

    func open(_ id: UUID) {
        guard let from = cardFrames[id] else { return land() }
        begin(id, opening: true, from: from, radius: Self.cardRadius)
    }

    func close(_ id: UUID) {
        guard let from = detailFrames[id], cardFrames[id] != nil else { return land() }
        begin(id, opening: false, from: from, radius: Self.detailRadius)
    }

    /// 飞行层第一次画出来以后才开始飞，否则新插入的封面会直接出现在终点。
    func layerAppeared(_ token: Int) {
        guard flight?.token == token else { return }
        layerShown = true
        launchIfReady()
        // 万一终点一直没报上来（比如卡片滚出了屏幕），别让封面卡在半路。
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            if flight?.token == token, flight?.started == false { land() }
        }
    }

    private func begin(_ id: UUID, opening: Bool, from: CGRect, radius: CGFloat) {
        nextToken += 1
        layerShown = false
        flight = Flight(id: id, token: nextToken, opening: opening, rect: from, radius: radius)
    }

    private func launchIfReady() {
        guard layerShown, let current = flight, !current.started,
              let target = current.opening ? detailFrames[current.id] : cardFrames[current.id] else { return }
        flight?.started = true
        withAnimation(Self.animation) {
            flight?.rect = target
            flight?.radius = current.opening ? Self.detailRadius : Self.cardRadius
        } completion: { [weak self] in
            if self?.flight?.token == current.token { self?.land() }
        }
    }

    private func land() { flight = nil }
}

extension EnvironmentValues {
    /// nil：不飞（减弱动态效果，或者不在游戏库里）。
    @Entry var coverFlight: CoverFlight?
}

extension View {
    /// 把这张封面的位置报告给飞行层。
    func reportsCoverFrame(_ action: @escaping (CGRect) -> Void) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(CoverFlight.space)) } action: { action($0) }
    }
}

/// 最上层飞着的那张封面。
struct CoverFlightLayer: View {
    let flight: CoverFlight
    let game: (UUID) -> (title: String, cover: NSImage?)?

    var body: some View {
        if let f = flight.flight, let info = game(f.id) {
            Color.clear.overlay {
                if let cover = info.cover {
                    Image(nsImage: cover).resizable().scaledToFill()
                } else {
                    CoverGradient(title: info.title)
                        .overlay {
                            Text(String(info.title.prefix(1)))
                                .font(.system(size: 60, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                }
            }
            .frame(width: f.rect.width, height: f.rect.height)
            .clipShape(RoundedRectangle(cornerRadius: f.radius))
            .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
            .offset(x: f.rect.minX, y: f.rect.minY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .transition(.identity)
            .id(f.token)
            .onAppear { flight.layerAppeared(f.token) }
        }
    }
}
