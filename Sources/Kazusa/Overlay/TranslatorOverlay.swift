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
    /// 文本钩子：直接从游戏进程读文本（只有用 Wine 启动、开着钩子的游戏才有）。
    case hook

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: "OCR（手动）"
        case .auto: "OCR（自动）"
        case .clipboard: "剪贴板"
        case .hook: "文本钩子"
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
    var status: String = "把上方的框拖到游戏的文本框上，然后点“识别”。" {
        didSet { statusIsError = false }
    }
    /// 错误在工具条上标红并带图标，普通提示用灰字。
    private(set) var statusIsError = false

    func showError(_ message: String) {
        status = message
        statusIsError = true
    }
    var isWorking = false
    var showHistory = false
    /// 字幕条下面是否显示原文（游戏画面里已经有原文，默认不显示）。
    var showSource = UserDefaults.standard.bool(forKey: "overlay.subtitle.showSource") {
        didSet { UserDefaults.standard.set(showSource, forKey: "overlay.subtitle.showSource") }
    }
    /// 锁定后取景框不再接收鼠标，点击直接落到下面的游戏上。
    var isLocked = false
    /// 正在流式输出的一句（原文, 目前为止的译文）。
    var pending: (source: String, translation: String)?

    /// 挂着文本钩子的游戏。
    var hookGameID: UUID?
    /// 能不能手动输入特殊码（只有 Wine 里的 LunaHook 能用，原生引擎自己输出台词）。
    var hookAcceptsCodes = true
    /// 钩到过文本的各路（给“文本来源”菜单用）。
    var hookThreads: [HookThreadSelector.ThreadState] = []
    var activeHookThread: String?
    var pinnedHookThread: String?
    /// 记着上次手动指定的那一路，但这次还没出现。
    var waitingForRememberedThread = false

    var availableModes: [TextSourceMode] {
        TextSourceMode.allCases.filter { $0 != .hook || hookGameID != nil }
    }
}

// MARK: - 视图

struct OverlayView: View {
    let controller: TranslatorOverlayController
    @Bindable var state: OverlayState

    static let barHeight: CGFloat = 132

    private var subtitle: Bool { state.mode == .hook }

    var body: some View {
        VStack(spacing: 0) {
            if subtitle {
                SubtitleBar(controller: controller, state: state) { controls }
            } else {
                CaptureFrame(controller: controller, locked: state.isLocked)
                translationBar
                    .frame(height: Self.barHeight)
            }
        }
    }

    private var translationBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.showHistory {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(state.lines.reversed()) { line in
                            LineView(line: line, large: false)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let pending = state.pending {
                LineView(source: pending.source, translation: pending.translation.isEmpty ? "…" : pending.translation,
                         large: subtitle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let line = state.lines.last {
                LineView(line: line, large: subtitle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Text(state.status)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            controls
        }
        .padding(12)
        .background(WindowDragArea())
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("文本来源方式", selection: Binding(get: { state.mode }, set: { controller.setMode($0) })) {
                ForEach(state.availableModes) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("从哪里拿到要翻译的文本")

            if subtitle {
                threadMenu
            } else {
                Button("识别") { controller.captureOnce() }
                    .disabled(state.isWorking)
                    .help("系统级快捷键 \(GlobalHotKeys.Combo.recognize.display)，游戏在前台也能用")
            }
            if subtitle {
                Toggle("原文", isOn: $state.showSource)
                    .toggleStyle(.button)
            }
            Toggle("历史", isOn: $state.showHistory)
                .toggleStyle(.button)
            if !subtitle {
                Button { controller.toggleLock() } label: {
                    Label(state.isLocked ? "解锁" : "锁定", systemImage: state.isLocked ? "lock.fill" : "lock.open").labelStyle(.iconOnly)
                }
                .help("锁定后点击穿透到游戏（\(GlobalHotKeys.Combo.toggleLock.display)）")
            }
            if state.isWorking { ProgressView().controlSize(.small) }
            if !state.status.isEmpty && !state.lines.isEmpty {
                Group {
                    if state.statusIsError {
                        Label(state.status, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    } else {
                        Text(state.status).foregroundStyle(.secondary)
                    }
                }
                .font(.caption).lineLimit(1)
                .help(state.status)
                .layoutPriority(-1)
            }
            Spacer(minLength: 0)
            Text(state.gameTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .layoutPriority(-2)
            Button { controller.close() } label: { Label("关闭", systemImage: "xmark").labelStyle(.iconOnly) }
                .buttonStyle(.borderless)
                .help("关闭翻译悬浮窗")
        }
    }

    /// 游戏里通常有好几路文本（对白、人名、菜单……），默认自动选字数最多的一路，也可以手动指定。
    private var threadMenu: some View {
        Menu {
            Button { controller.pinHookThread(nil) } label: {
                if state.pinnedHookThread == nil { Label("自动选择", systemImage: "checkmark") } else { Text("自动选择") }
            }
            if state.waitingForRememberedThread {
                Text("已记住上次指定的文本来源，出现后自动切过去")
            }
            if !state.hookThreads.isEmpty { Divider() }
            ForEach(state.hookThreads) { t in
                let sample = t.lastText.count > 24 ? String(t.lastText.prefix(24)) + "…" : t.lastText
                let title = "\(t.thread.name.isEmpty ? "文本" : t.thread.name)：\(sample)"
                Button { controller.pinHookThread(t.id) } label: {
                    if state.pinnedHookThread == t.id { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
            if state.hookAcceptsCodes {
                Divider()
                Button("输入特殊码…") { controller.promptHookCode() }
            }
        } label: {
            Text(state.pinnedHookThread == nil ? "自动选择" : "手动指定")
        }
        .fixedSize()
        .help("选择翻译哪个文本来源（对白、人名、选项）；手动选的会按游戏记住。钩不到对白时可以输入特殊码")
    }
}

private struct LineView: View {
    let source: String
    let translation: String
    /// 字幕条用大字。
    let large: Bool

    init(line: TranslationSession.Line, large: Bool) {
        self.init(source: line.source, translation: line.translation, large: large)
    }

    init(source: String, translation: String, large: Bool) {
        self.source = source
        self.translation = translation
        self.large = large
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(translation)
                .font(.system(size: large ? 22 : 17, weight: .medium))
                .textSelection(.enabled)
            Text(source)
                .font(large ? .callout : .caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

/// 文本钩子模式的字幕条：平时只有译文和文字后面一层半透明底，
/// 鼠标移上去才显示背景和按钮（可以拖动、改大小、选文本来源）。
private struct SubtitleBar<Controls: View>: View {
    let controller: TranslatorOverlayController
    @Bindable var state: OverlayState
    @ViewBuilder let controls: () -> Controls
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .top) {
            if hovering || state.showHistory {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.ultraThinMaterial)
                    .background(WindowDragArea())
            }
            if state.showHistory {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(state.lines.reversed()) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.translation).font(.system(size: 15, weight: .medium))
                                Text(line.source).font(.caption).foregroundStyle(.secondary)
                            }
                            .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                .padding(.top, 40)
            } else {
                caption
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
            if hovering || state.showHistory {
                controls()
                    .padding(8)
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(.easeInOut(duration: 0.15)) { hovering = inside } }
    }

    @ViewBuilder private var caption: some View {
        let shown: (source: String, translation: String)? =
            state.pending.map { ($0.source, $0.translation.isEmpty ? "…" : $0.translation) }
            ?? state.lines.last.map { ($0.source, $0.translation) }
        if let shown {
            VStack(spacing: 3) {
                Text(shown.translation)
                    .font(.system(size: 22, weight: .medium))
                if state.showSource {
                    Text(shown.source)
                        .font(.system(size: 14))
                        .opacity(0.75)
                }
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.9), radius: 2)
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        } else {
            // 还没有译文时也留一小块可见的底，鼠标移上去才能呼出按钮（全透明的地方点击会穿透到游戏）。
            Text(hovering ? state.status : "字幕条")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// 拖动这里移动悬浮窗（字幕条没有取景框可以拖）。
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
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
