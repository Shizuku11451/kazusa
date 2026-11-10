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
        case .manual: "手动"
        case .auto: "自动 OCR"
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
    var status: String = "把上方的框拖到游戏的文本框上，然后点“识别”。"
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

/// 翻译悬浮窗。
/// - OCR 模式：上半部分是透明的“取景框”（截图区域），下半部分显示译文；
/// - 文本钩子模式：只有一条字幕条，默认放在屏幕下方。
@MainActor
final class TranslatorOverlayController {
    private unowned let model: AppModel
    let state = OverlayState()
    private var panel: NSPanel?
    private var session: TranslationSession?
    /// session 属于哪个游戏；换游戏时换一个 session（各自的翻译记录）。
    private var sessionGameID: UUID?
    private var loopTask: Task<Void, Never>?
    /// 取景框对应的 NSView，用来换算屏幕坐标。
    weak var captureView: NSView?

    private var lastOCRText = ""
    private var lastClipboardChange = NSPasteboard.general.changeCount
    /// 每次翻译递增；迟到的流式回调对不上就丢弃。
    private var streamGeneration = 0
    private var gameID: UUID?

    private var selector = HookThreadSelector()
    /// 字幕条跟着游戏窗口走。
    private var windowTracker: GameWindowTracker?
    /// 字幕条用的是默认位置（这个游戏还没存过）：找到游戏窗口后挪到窗口底部。
    private var subtitleAtDefaultPosition = false
    /// 用户输入过的特殊码（比较用的形式），只对这些显示“已插入”。LunaHook 自动下的钩子也会报插入。
    private var manualHookCodes: Set<String> = []

    private static func codeKey(_ code: String) -> String {
        (code.hasPrefix("/") ? String(code.dropFirst()) : code).uppercased()
    }
    /// 翻译进行中时到达的最新一句；翻完当前这句只翻它，中间跳过的不再翻。
    private var queuedText: String?
    private var draining = false

    init(model: AppModel) {
        self.model = model
    }

    func show(game: Game?) {
        if let game {
            state.gameTitle = game.title
            state.locale = game.locale
            state.glossary = game.translation.glossary
            gameID = game.id
        }
        rebuildSession()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        applyLayout()
        panel.orderFrontRegardless()
    }

    /// 每个游戏的窗口位置 / 文本框位置都不一样：按游戏、按模式（取景框 / 字幕条）分别记住位置和大小。
    private func applyLayout() {
        guard let panel else { return }
        let subtitle = state.mode == .hook
        panel.minSize = subtitle ? NSSize(width: 360, height: 90) : NSSize(width: 320, height: 200)
        let name = "KazusaOverlay-\(gameID?.uuidString ?? "default")\(subtitle ? "-subtitle" : "")"
        guard panel.frameAutosaveName != name else { return }
        panel.setFrameAutosaveName("")
        let restored = panel.setFrameUsingName(name)
        if subtitle { subtitleAtDefaultPosition = !restored }
        if !restored {
            if subtitle, let gameFrame = windowTracker?.frame {
                placeSubtitle(in: gameFrame)
            } else if subtitle, let screen = NSScreen.main?.visibleFrame {
                let width = min(960, screen.width - 80)
                panel.setFrame(NSRect(x: screen.midX - width / 2, y: screen.minY + 40, width: width, height: 150), display: true)
            } else if !subtitle {
                panel.setContentSize(NSSize(width: 760, height: 320))
            }
        }
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
        if state.mode != .hook { setMode(.manual) }
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
        if let session, sessionGameID == gameID {
            let glossary = state.glossary
            Task {
                await session.update(translator: translator, glossary: glossary)
                // 改了目标语言时记录会换成对应语言的。
                if self.session === session { state.lines = await session.lines }
            }
        } else {
            let store = gameID.map { model.paths.translationStore(for: $0) }
            let session = TranslationSession(translator: translator, glossary: state.glossary, store: store)
            self.session = session
            sessionGameID = gameID
            state.pending = nil
            state.lines = []
            Task { if self.session === session { state.lines = await session.lines } }
        }
    }

    /// 清空某个游戏的翻译记录。悬浮窗正开着这个游戏时连同显示的内容一起清掉。
    func clearTranslations(for id: UUID) throws {
        if let session, sessionGameID == id {
            state.lines = []
            Task { try? await session.clear() }
        }
        try model.paths.translationStore(for: id).clear()
    }

    // MARK: - 文本来源

    func setMode(_ mode: TextSourceMode) {
        state.mode = mode
        loopTask?.cancel()
        loopTask = nil
        applyLayout()
        switch mode {
        case .manual, .hook:
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

    // MARK: - 文本钩子

    /// 游戏刚用 Wine 启动、钩子程序即将运行：切到字幕条。
    func beginHook(game: Game) {
        selector = HookThreadSelector(remembered: game.translation.hookThread)
        manualHookCodes = Set((game.translation.hookCodes ?? []).map(Self.codeKey))
        queuedText = nil
        state.hookGameID = game.id
        syncThreads()
        startFollowing(game)
        show(game: game)
        setMode(.hook)
        state.status = "正在连接游戏…"
    }

    func hookFailed(_ message: String) {
        stopFollowing()
        state.hookGameID = nil
        setMode(.manual)
        state.status = "文本钩子没能启动：\(message)。可以改用 OCR。"
    }

    func handleHook(_ event: HookEvent?, gameID: UUID) {
        guard state.hookGameID == gameID else { return }
        func info(_ text: String) {
            // 已经有译文时不打扰；状态栏里的文字在有译文时是红色的错误提示。
            if state.lines.isEmpty { state.status = text }
        }
        switch event {
        case nil:
            stopFollowing()
            info("文本钩子已退出。")
        case .ready:
            info("已连接，推进一句对白试试。")
        case .info(level: 4, let engine):
            info("识别到 \(engine) 引擎，推进一句对白试试。")
        case .hookInserted(let code) where manualHookCodes.contains(Self.codeKey(code)):
            state.status = "特殊码已插入：\(code)。推进一句对白，再到“文本来源”里选新出现的那一路。"
        case .info, .hookInserted:
            break
        case .thread(let thread):
            selector.register(thread)
            syncThreads()
        case .threadRemoved(let id):
            selector.remove(id: id)
            syncThreads()
        case .text(let threadID, let text):
            let line = selector.accept(threadID: threadID, text: text)
            syncThreads()
            if let line, state.mode == .hook { enqueue(line) }
        case .detached:
            info("游戏和文本钩子断开了。")
        case .error(let message):
            state.status = message
        }
    }

    /// 手动指定翻译哪一路并按游戏记住；nil 表示回到自动。
    func pinHookThread(_ id: String?) {
        let key = selector.pin(id)
        if let gameID = state.hookGameID { model.rememberHookThread(key, for: gameID) }
        syncThreads()
    }

    /// 弹窗输入特殊码（H 码 / R 码）。插入后记在游戏设置里，以后每次连上游戏自动插入。
    func promptHookCode() {
        guard let gameID = state.hookGameID else { return }
        let alert = NSAlert()
        alert.messageText = "输入特殊码"
        alert.informativeText = "自动钩不到对白时，可以填网上找到的特殊码（H 码），例如 /HS-1C@44F7B0:WA2.exe。"
            + "插入后会记在这个游戏的设置里，以后每次启动自动插入。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "/HS-1C@44F7B0:game.exe"
        alert.accessoryView = field
        alert.addButton(withTitle: "插入")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let code = HookCode.normalize(field.stringValue) else {
            state.status = "特殊码不能为空，也不能有多行。"
            return
        }
        manualHookCodes.insert(Self.codeKey(code))
        state.status = model.insertHookCode(code, for: gameID)
            ? "正在插入特殊码 \(code)…"
            : "已记下特殊码，下次启动游戏时插入。"
    }

    private func syncThreads() {
        state.hookThreads = selector.threads.filter { $0.score > 0 }
        state.activeHookThread = selector.activeThreadID
        state.pinnedHookThread = selector.pinnedThreadID
        state.waitingForRememberedThread = selector.remembered != nil && selector.pinnedThreadID == nil
    }

    // MARK: - 跟随游戏窗口

    private func startFollowing(_ game: Game) {
        stopFollowing()
        let tracker = GameWindowTracker(executable: game.executableURL) { [weak self] old, new in
            self?.gameWindowMoved(from: old, to: new)
        }
        windowTracker = tracker
        tracker.start()
    }

    private func stopFollowing() {
        windowTracker?.stop()
        windowTracker = nil
    }

    /// 游戏窗口挪了（或改了大小、进出全屏）：字幕条保持和窗口底边中点的相对位置。
    /// 用户自己拖过字幕条的话，拖出来的偏移也保留。
    private func gameWindowMoved(from old: NSRect?, to new: NSRect) {
        guard let panel, state.mode == .hook else { return }
        guard let old else {
            if subtitleAtDefaultPosition { placeSubtitle(in: new) }
            return
        }
        var origin = panel.frame.origin
        origin.x += new.midX - old.midX
        origin.y += new.minY - old.minY
        panel.setFrameOrigin(origin)
    }

    /// 默认位置：游戏窗口底部居中，宽度不超过窗口。
    private func placeSubtitle(in game: NSRect) {
        guard let panel else { return }
        let width = min(960, max(360, game.width - 40))
        let height = max(panel.frame.height, 150)
        panel.setFrame(NSRect(x: game.midX - width / 2, y: game.minY + 20, width: width, height: height), display: true)
        subtitleAtDefaultPosition = false
    }

    private func enqueue(_ text: String) {
        queuedText = text
        guard !draining else { return }
        draining = true
        Task {
            while let next = queuedText {
                queuedText = nil
                await translate(next)
            }
            draining = false
        }
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
                state.status = await session.storeError.map { "翻译记录没能保存：\($0)" } ?? ""
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
            Picker("", selection: Binding(get: { state.mode }, set: { controller.setMode($0) })) {
                ForEach(state.availableModes) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: state.hookGameID == nil ? 220 : 300)

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
                    Image(systemName: state.isLocked ? "lock.fill" : "lock.open")
                }
                .help("锁定后点击穿透到游戏（\(GlobalHotKeys.Combo.toggleLock.display)）")
            }
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

    /// 游戏里通常有好几路文本（对白、人名、菜单……），默认自动选字数最多的一路，也可以手动指定。
    private var threadMenu: some View {
        Menu {
            Button { controller.pinHookThread(nil) } label: {
                if state.pinnedHookThread == nil { Label("自动选择", systemImage: "checkmark") } else { Text("自动选择") }
            }
            if state.waitingForRememberedThread {
                Text("已记住上次指定的那一路，出现后自动切过去")
            }
            if !state.hookThreads.isEmpty { Divider() }
            ForEach(state.hookThreads) { t in
                let sample = t.lastText.count > 24 ? String(t.lastText.prefix(24)) + "…" : t.lastText
                let title = "\(t.thread.name.isEmpty ? "文本" : t.thread.name)：\(sample)"
                Button { controller.pinHookThread(t.id) } label: {
                    if state.pinnedHookThread == t.id { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
            Divider()
            Button("输入特殊码…") { controller.promptHookCode() }
        } label: {
            Text(state.pinnedHookThread == nil ? "自动选择" : "手动指定")
        }
        .fixedSize()
        .help("游戏有好几路文本时（对白、人名、选项），选择翻译哪一路；手动选的会按游戏记住。钩不到对白时可以输入特殊码")
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
