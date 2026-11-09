// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import AppKit
import KazusaCore
import Observation
import SwiftUI

/// 文本来源。
enum TextSourceMode: String, CaseIterable, Identifiable {
    /// 手动点按钮（或 ⇧⌘R）识别一次。
    case manual
    /// 定时截图识别，画面文字稳定后自动翻译。
    case auto
    /// 监听剪贴板：配合把文本复制到剪贴板的提取工具使用。
    case clipboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: "手动"
        case .auto: "自动 OCR"
        case .clipboard: "剪贴板"
        }
    }
}

@MainActor
@Observable
final class OverlayState {
    var gameTitle: String = "未选择游戏"
    var locale: GameLocale = .japanese
    var glossary: [String: String] = [:]
    var mode: TextSourceMode = .manual
    var lines: [TranslationSession.Line] = []
    var status: String = "把上方的框拖到游戏的文本框上，然后点“识别”。"
    var isWorking = false
    var showHistory = false
    /// 锁定后取景框不再接收鼠标，点击直接落到下面的游戏上。
    var isLocked = false
    /// 正在流式输出的一句（原文, 目前为止的译文）。
    var pending: (source: String, translation: String)?
}

/// 翻译悬浮窗：上半部分是透明的“取景框”（截图区域），下半部分显示译文。
@MainActor
final class TranslatorOverlayController {
    private unowned let model: AppModel
    let state = OverlayState()
    private var panel: NSPanel?
    private var session: TranslationSession?
    private var loopTask: Task<Void, Never>?
    /// 取景框对应的 NSView，用来换算屏幕坐标。
    weak var captureView: NSView?

    private var lastOCRText = ""
    private var lastClipboardChange = NSPasteboard.general.changeCount
    /// 每次翻译递增；迟到的流式回调对不上就丢弃。
    private var streamGeneration = 0

    init(model: AppModel) {
        self.model = model
    }

    func show(game: Game?) {
        if let game {
            state.gameTitle = game.title
            state.locale = game.locale
            state.glossary = game.translation.glossary
        }
        rebuildSession()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        restoreFrame(of: panel, for: game)
        panel.orderFrontRegardless()
    }

    /// 每个游戏的窗口位置 / 文本框位置都不一样：按游戏分别记住悬浮窗的位置和大小。
    private func restoreFrame(of panel: NSPanel, for game: Game?) {
        let name = "KazusaOverlay-\(game?.id.uuidString ?? "default")"
        guard panel.frameAutosaveName != name else { return }
        panel.setFrameAutosaveName("")
        panel.setFrameUsingName(name)
        panel.setFrameAutosaveName(name)
    }

    func toggleLock() {
        if panel == nil { show(game: model.selectedGame) }
        state.isLocked.toggle()
        state.status = state.isLocked
            ? "已锁定：点击会穿透到游戏。按 \(GlobalHotKeys.Combo.toggleLock.display) 解锁。"
            : "已解锁：可以拖动取景框。"
    }

    func close() {
        setMode(.manual)
        panel?.orderOut(nil)
    }

    func settingsDidChange() {
        guard session != nil else { return }
        rebuildSession()
    }

    private func rebuildSession() {
        guard let translator = model.makeTranslator() else {
            session = nil
            state.status = "还没有配置翻译服务：打开 设置 → 翻译。"
            return
        }
        if let session {
            let glossary = state.glossary
            Task { await session.update(translator: translator, glossary: glossary) }
        } else {
            session = TranslationSession(translator: translator, glossary: state.glossary)
        }
    }

    // MARK: - 文本来源

    func setMode(_ mode: TextSourceMode) {
        state.mode = mode
        loopTask?.cancel()
        loopTask = nil
        switch mode {
        case .manual:
            break
        case .auto:
            lastOCRText = ""
            loopTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.autoTick()
                    try? await Task.sleep(for: .milliseconds(1200))
                }
            }
        case .clipboard:
            lastClipboardChange = NSPasteboard.general.changeCount
            loopTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.clipboardTick()
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }
        }
    }

    func captureOnce() {
        if panel == nil { show(game: model.selectedGame) }
        Task {
            guard let text = await ocr() else { return }
            await translate(text)
        }
    }

    /// 自动模式：连续两次识别结果一致（画面稳定、打字机效果结束）才翻译。
    private func autoTick() async {
        guard !state.isWorking, let text = await ocr(quiet: true) else { return }
        let normalized = TranslationSession.normalize(text)
        defer { lastOCRText = normalized }
        guard !normalized.isEmpty, normalized == lastOCRText else { return }
        await translate(normalized)
    }

    private func clipboardTick() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastClipboardChange else { return }
        lastClipboardChange = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string) else { return }
        Task { await translate(text) }
    }

    private func ocr(quiet: Bool = false) async -> String? {
        guard let rect = captureRectOnScreen() else { return nil }
        do {
            return try await ScreenTextCapture.recognizeText(in: rect, languages: state.locale.ocrLanguages)
        } catch {
            if !quiet || error is ScreenTextCapture.CaptureError {
                state.status = error.localizedDescription
            }
            if error is ScreenTextCapture.CaptureError { setMode(.manual) }
            return nil
        }
    }

    private func translate(_ text: String) async {
        guard let session else {
            state.status = "还没有配置翻译服务：打开 设置 → 翻译。"
            return
        }
        state.isWorking = true
        streamGeneration += 1
        let generation = streamGeneration
        defer {
            state.isWorking = false
            state.pending = nil
            streamGeneration += 1
        }
        do {
            let line = try await session.submit(text) { [weak self] source, partial in
                Task { @MainActor in
                    guard let self, self.streamGeneration == generation else { return }
                    // 主线程任务的执行顺序不保证与回调顺序一致：只接受更长的部分结果。
                    if let current = self.state.pending, current.translation.count > partial.count { return }
                    self.state.pending = (source, partial)
                }
            }
            if line != nil {
                state.lines = await session.lines
                state.status = ""
            }
        } catch {
            state.status = error.localizedDescription
        }
    }

    private func captureRectOnScreen() -> NSRect? {
        guard let view = captureView, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    // MARK: - 窗口

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 200, y: 200, width: 760, height: 320),
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 320, height: 200)
        panel.contentView = NSHostingView(rootView: OverlayView(controller: self, state: state))
        panel.center()
        return panel
    }
}

// MARK: - 视图

struct OverlayView: View {
    let controller: TranslatorOverlayController
    @Bindable var state: OverlayState

    static let barHeight: CGFloat = 132

    var body: some View {
        VStack(spacing: 0) {
            CaptureFrame(controller: controller, locked: state.isLocked)
            translationBar
                .frame(height: Self.barHeight)
        }
    }

    private var translationBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.showHistory {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(state.lines.reversed()) { line in
                            LineView(line: line)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let pending = state.pending {
                LineView(source: pending.source, translation: pending.translation.isEmpty ? "…" : pending.translation)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let line = state.lines.last {
                LineView(line: line)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Text(state.status)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            HStack(spacing: 10) {
                Picker("", selection: Binding(get: { state.mode }, set: { controller.setMode($0) })) {
                    ForEach(TextSourceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)

                Button("识别") { controller.captureOnce() }
                    .disabled(state.isWorking)
                    .help("系统级快捷键 \(GlobalHotKeys.Combo.recognize.display)，游戏在前台也能用")
                Toggle("历史", isOn: $state.showHistory)
                    .toggleStyle(.button)
                Button { controller.toggleLock() } label: {
                    Image(systemName: state.isLocked ? "lock.fill" : "lock.open")
                }
                .help("锁定后点击穿透到游戏（\(GlobalHotKeys.Combo.toggleLock.display)）")
                if state.isWorking { ProgressView().controlSize(.small) }
                if !state.status.isEmpty && !state.lines.isEmpty {
                    Text(state.status).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
                Spacer()
                Text(state.gameTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Button { controller.close() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
        }
        .padding(12)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct LineView: View {
    let source: String
    let translation: String

    init(line: TranslationSession.Line) {
        self.init(source: line.source, translation: line.translation)
    }

    init(source: String, translation: String) {
        self.source = source
        self.translation = translation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(translation)
                .font(.system(size: 17, weight: .medium))
                .textSelection(.enabled)
            Text(source)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

/// 透明取景框：可以拖动窗口，同时把自己的 NSView 交给控制器换算截图区域。
private struct CaptureFrame: NSViewRepresentable {
    let controller: TranslatorOverlayController
    let locked: Bool

    func makeNSView(context: Context) -> CaptureFrameView {
        let view = CaptureFrameView()
        view.locked = locked
        controller.captureView = view
        return view
    }

    func updateNSView(_ nsView: CaptureFrameView, context: Context) {
        nsView.locked = locked
        controller.captureView = nsView
    }
}

final class CaptureFrameView: NSView {
    override var isFlipped: Bool { true }

    var locked = false {
        didSet { if locked != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        // 未锁定时铺一层几乎透明的底色，保证鼠标事件落在这里；
        // 锁定时不铺，完全透明的像素会让窗口服务器把点击直接交给下层的游戏窗口。
        if !locked {
            NSColor.black.withAlphaComponent(0.01).setFill()
            bounds.fill()
        }

        let color = locked ? NSColor.systemPink.withAlphaComponent(0.35) : NSColor.systemPink
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 8, yRadius: 8)
        path.lineWidth = locked ? 1 : 2
        path.setLineDash([8, 5], count: 2, phase: 0)
        color.setStroke()
        path.stroke()

        if !locked {
            let label = "取景框：拖动到游戏文本上（拖边缘可调整大小），锁定后点击穿透" as NSString
            label.draw(at: NSPoint(x: 12, y: 8), withAttributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: color,
            ])
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        locked ? nil : super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        needsDisplay = true
    }
}
