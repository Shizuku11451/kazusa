// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import AppKit
import KazusaCore
import Observation
import SwiftUI

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
            state.showError("还没有配置翻译服务：打开 设置 → 翻译。")
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

    /// 游戏刚启动、即将收到钩到的文本：切到字幕条。
    /// - Parameter nativePID: 原生引擎的进程号。原生引擎自己输出台词，没有特殊码可插。
    func beginHook(game: Game, nativePID: pid_t? = nil) {
        selector = HookThreadSelector(remembered: game.translation.hookThread)
        manualHookCodes = Set((game.translation.hookCodes ?? []).map(Self.codeKey))
        queuedText = nil
        state.hookGameID = game.id
        state.hookAcceptsCodes = nativePID == nil
        syncThreads()
        startFollowing(game, pid: nativePID)
        show(game: game)
        setMode(.hook)
        state.status = nativePID == nil ? "正在连接游戏…" : "推进一句对白，台词会显示在这里。"
    }

    func hookFailed(_ message: String) {
        stopFollowing()
        state.hookGameID = nil
        setMode(.manual)
        state.showError("文本钩子没能启动：\(message)。可以改用 OCR。")
    }

    func handleHook(_ event: HookEvent?, gameID: UUID) {
        guard state.hookGameID == gameID else { return }
        func info(_ text: String) {
            // 已经有译文时不打扰。
            if state.lines.isEmpty { state.status = text }
        }
        switch event {
        case nil:
            stopFollowing()
            info(state.hookAcceptsCodes ? "文本钩子已退出。" : "游戏已退出。")
        case .ready:
            info("已连接，推进一句对白试试。")
        case .info(level: 4, let engine):
            info("识别到 \(engine) 引擎，推进一句对白试试。")
        case .hookInserted(let code) where manualHookCodes.contains(Self.codeKey(code)):
            state.status = "特殊码已插入：\(code)。推进一句对白，再到“文本来源”里选新出现的那个。"
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
            state.showError(message)
        }
    }

    /// 手动指定翻译哪个文本来源并按游戏记住；nil 表示回到自动。
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
            state.showError("特殊码不能为空，也不能有多行。")
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

    private func startFollowing(_ game: Game, pid: pid_t?) {
        stopFollowing()
        let tracker = GameWindowTracker(executable: pid == nil ? game.executableURL : nil, pid: pid) { [weak self] old, new in
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
                state.showError(error.localizedDescription)
            }
            if error is ScreenTextCapture.CaptureError { setMode(.manual) }
            return nil
        }
    }

    private func translate(_ text: String) async {
        guard let session else {
            state.showError("还没有配置翻译服务：打开 设置 → 翻译。")
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
                if let storeError = await session.storeError {
                    state.showError("翻译记录没能保存：\(storeError)")
                } else {
                    state.status = ""
                }
            }
        } catch {
            state.showError(error.localizedDescription)
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
