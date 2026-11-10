// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import AppKit
import KazusaCore
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    let paths = KazusaPaths.default
    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let launcher: GameLauncher
    @ObservationIgnored let covers: CoverStore
    /// 已加载的封面。没有封面的游戏不在这里，卡片上显示渐变占位。
    var coverImages: [UUID: NSImage] = [:]
    /// 正在为哪个游戏打开“搜索封面”窗口。
    var coverSearch: GameRequest?
    /// 正在编辑哪个游戏的设置（运行方式、翻译等）。
    var gameSettings: GameRequest?
    /// 等用户确认的“从游戏库移除”和“停止”。
    var confirmingRemoval: GameRequest?
    var confirmingStop: GameRequest?
    /// 正在从 VNDB 拉取资料的游戏。
    var metadataLoading: Set<UUID> = []
    /// 正在翻译简介的游戏，值是目前为止流式收到的译文。
    var synopsisTranslating: [UUID: String] = [:]

    var games: [Game] = []
    var selectedGameID: UUID?
    /// 当前打开的游戏详情页；为空时显示游戏库。
    var openedGameID: UUID?
    var runningGameIDs: Set<UUID> = []
    var runtimes: [WineRuntime] = []
    /// 正在进行的长操作（初始化前缀等），显示在界面上。
    var busyMessage: String?
    var alert: AlertItem?
    /// 设置窗口当前的标签页；从别处跳过去时先改它再打开设置。
    var settingsTab: SettingsTab = .runtime

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            scheduleSave(settings: true)
        }
    }

    @ObservationIgnored lazy var overlay = TranslatorOverlayController(model: self)
    /// 正在运行的文本钩子，按游戏 ID。
    @ObservationIgnored private var hookHosts: [UUID: TextHookHost] = [:]
    @ObservationIgnored private var nativeTextSources: [UUID: NativeTextSource] = [:]

    /// 打开游戏详情页，同时选中它（翻译悬浮窗会用选中的游戏）。
    func open(_ id: UUID) {
        selectedGameID = id
        openedGameID = id
    }

    struct GameRequest: Identifiable {
        let id: UUID
    }

    struct AlertItem: Identifiable {
        let id = UUID()
        var title: String
        var message: String
        /// 不为空时弹窗里多一个“去设置”按钮，跳到对应标签页。
        var settingsTab: SettingsTab?
    }

    enum SettingsTab: Hashable {
        case runtime, translation
    }

    init() {
        store = LibraryStore(fileURL: paths.libraryFile)
        launcher = GameLauncher(paths: paths)
        covers = CoverStore(paths: paths)
        settings = AppSettings.load(from: paths.settingsFile)
        do {
            try paths.ensureDirectories()
            games = try store.load()
        } catch {
            report(error)
        }
        refreshRuntimes()
        registerHotKeys()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushPendingSaves() }
        }
        for game in games { refreshNativeSupport(for: game) }
        Task {
            await loadCovers()
            for game in games where coverImages[game.id] == nil {
                autoFetchCover(for: game.id)
            }
            // 旧版本没有资料，或者资料里还没有截图 / 角色，补拉一次。
            for game in games where game.vndbID != nil && game.metadata?.characters == nil && coverImages[game.id] != nil {
                fetchMetadata(for: game.id)
            }
        }
    }

    private func registerHotKeys() {
        GlobalHotKeys.shared.register(.recognize) { [weak self] in self?.overlay.captureOnce() }
        GlobalHotKeys.shared.register(.toggleLock) { [weak self] in self?.overlay.toggleLock() }
    }

    // MARK: - 游戏库

    var selectedGame: Game? {
        games.first { $0.id == selectedGameID }
    }

    func binding(for id: UUID) -> Binding<Game>? {
        guard games.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.games.first { $0.id == id } ?? self.placeholderGame },
            set: { newValue in
                guard let i = self.games.firstIndex(where: { $0.id == id }) else { return }
                self.games[i] = newValue
                self.scheduleSave(games: true)
            }
        )
    }

    private var placeholderGame: Game {
        Game(title: "", directory: URL(fileURLWithPath: "/"), executable: "", engine: .unknown, locale: .simplifiedChinese)
    }

    func saveGames() {
        do { try store.save(games) } catch { report(error) }
    }

    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var gamesDirty = false
    @ObservationIgnored private var settingsDirty = false

    /// 输入框每敲一个字都会改模型：内存里立刻生效，写盘合并到停手 0.4 秒后。
    private func scheduleSave(games: Bool = false, settings: Bool = false) {
        gamesDirty = gamesDirty || games
        settingsDirty = settingsDirty || settings
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.flushPendingSaves()
        }
    }

    /// 把还没写的改动立刻写盘（退出程序时也会调用）。
    func flushPendingSaves() {
        pendingSave?.cancel()
        pendingSave = nil
        if gamesDirty {
            gamesDirty = false
            saveGames()
        }
        if settingsDirty {
            settingsDirty = false
            do { try settings.save(to: paths.settingsFile) } catch { report(error) }
            overlay.settingsDidChange()
        }
    }

    func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.title = "选择游戏文件夹或主程序 (.exe)"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.folder, .exe]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { importGame(at: url) }
    }

    /// 导入一个游戏。可以是文件夹，也可以直接是 exe（此时用它所在的文件夹并选中它）。
    func importGame(at url: URL) {
        let isExe = url.pathExtension.lowercased() == "exe"
        let directory = isExe ? url.deletingLastPathComponent() : url
        if let existing = games.first(where: { $0.directory.standardizedFileURL == directory.standardizedFileURL }) {
            selectedGameID = existing.id
            return
        }
        Task {
            let inspection = await Task.detached { GameInspector.inspect(directory: directory) }.value
            // NScripter / KiriKiri 游戏可以没有 exe（只有脚本和封包），用原生引擎运行。
            let nativeOnly = nativeBinaries[inspection.engine.engine] != nil
            let executable = isExe ? url.lastPathComponent : inspection.suggestedExecutable ?? (nativeOnly ? "" : nil)
            guard let executable else {
                alert = AlertItem(title: "没有找到游戏程序", message: "“\(directory.lastPathComponent)”里没有 .exe 文件。")
                return
            }
            let game = Game(
                title: inspection.title,
                directory: directory,
                executable: executable,
                engine: inspection.engine.engine,
                locale: inspection.suggestedLocale
            )
            games.append(game)
            games.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            selectedGameID = game.id
            saveGames()
            refreshNativeSupport(for: game)
            autoFetchCover(for: game.id)
        }
    }

    func remove(_ game: Game) {
        games.removeAll { $0.id == game.id }
        if selectedGameID == game.id { selectedGameID = nil }
        if openedGameID == game.id { openedGameID = nil }
        saveGames()
        covers.remove(for: game.id)
        coverImages[game.id] = nil
        try? overlay.clearTranslations(for: game.id)
    }

    func clearTranslations(for id: UUID) {
        do { try overlay.clearTranslations(for: id) } catch { report(error) }
    }

    // MARK: - 封面

    /// 封面文件在后台读，不卡启动。
    private func loadCovers() async {
        let covers = covers
        let ids = games.map(\.id)
        let loaded = await Task.detached { ids.compactMap { id in covers.data(for: id).map { (id, $0) } } }.value
        // 读的时候用户可能已经换了封面。
        for (id, data) in loaded where coverImages[id] == nil {
            if let image = NSImage(data: data) { coverImages[id] = image }
        }
    }

    /// 没有封面时自动找一张：先看游戏目录里有没有现成的图，再按标题查 VNDB。
    /// 用了目录里的图时，仍然按标题去 VNDB 匹配一次资料。
    /// 静默进行，找不到或没网也不打扰用户。
    func autoFetchCover(for id: UUID) {
        guard let game = games.first(where: { $0.id == id }) else { return }
        let directory = game.directory
        let title = game.title
        Task {
            if let data = await Task.detached(operation: { LocalCoverFinder.find(in: directory) }).value {
                try? setCover(data, for: id)
                if game.vndbID == nil { await matchMetadata(for: id, silent: true) }
                return
            }
            guard let entry = try? await VNDB.bestMatch(for: title) else { return }
            // 等待期间用户可能已经手动设置了封面。
            guard coverImages[id] == nil else { return }
            try? await applyCover(from: entry, to: id)
        }
    }

    /// 下载 VNDB 条目的封面并记下条目编号，顺便拉取资料。
    func applyCover(from entry: VNDBEntry, to id: UUID) async throws {
        let data = try await VNDB.downloadImage(entry)
        try setCover(data, for: id)
        link(id, toVNDB: entry.id)
    }

    func setCover(_ data: Data, for id: UUID) throws {
        try covers.save(data, for: id)
        coverImages[id] = NSImage(data: data)
    }

    func setCover(fromFile url: URL, for id: UUID) {
        do {
            try setCover(Data(contentsOf: url), for: id)
        } catch {
            report(error)
        }
    }

    func chooseCoverFile(for id: UUID) {
        let panel = NSOpenPanel()
        panel.title = "选择封面图片"
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setCover(fromFile: url, for: id)
    }

    /// 只移除图片；VNDB 关联和资料保留。
    func removeCover(for id: UUID) {
        covers.remove(for: id)
        coverImages[id] = nil
    }

    // MARK: - VNDB 资料

    /// 记下 VNDB 条目编号；换了条目或还没有资料时去拉取。
    private func link(_ id: UUID, toVNDB vndbID: String) {
        guard let i = games.firstIndex(where: { $0.id == id }) else { return }
        let changed = games[i].vndbID != vndbID
        games[i].vndbID = vndbID
        if changed { games[i].metadata = nil }
        saveGames()
        if changed || games[i].metadata == nil { fetchMetadata(for: id) }
    }

    /// 按已记下的条目编号拉取资料。`silent` 时出错不弹窗（启动时的自动补拉）。
    func fetchMetadata(for id: UUID, silent: Bool = true) {
        guard let vndbID = games.first(where: { $0.id == id })?.vndbID, !metadataLoading.contains(id) else { return }
        metadataLoading.insert(id)
        Task {
            defer { metadataLoading.remove(id) }
            do {
                let metadata = try await VNDB.details(id: vndbID)
                // 等待期间用户可能换了条目或解除了关联。
                guard let i = games.firstIndex(where: { $0.id == id }), games[i].vndbID == vndbID else { return }
                games[i].metadata = metadata.keepingTranslation(from: games[i].metadata)
                saveGames()
            } catch {
                if !silent { report(error) }
            }
        }
    }

    /// 没有关联条目时，按标题在 VNDB 上找最像的一条（不替换封面）。
    func matchMetadata(for id: UUID, silent: Bool = false) async {
        guard let title = games.first(where: { $0.id == id })?.title, !metadataLoading.contains(id) else { return }
        metadataLoading.insert(id)
        let result: Result<VNDBEntry?, Error>
        do { result = .success(try await VNDB.bestMatch(for: title, requireSafeImage: false)) } catch { result = .failure(error) }
        // 先清掉标记，link 里的 fetchMetadata 会重新标上。
        metadataLoading.remove(id)
        switch result {
        case .success(let entry?):
            // 等待期间用户可能已经手动选了条目。
            guard games.first(where: { $0.id == id })?.vndbID == nil else { return }
            link(id, toVNDB: entry.id)
        case .success(nil):
            if !silent {
                alert = AlertItem(title: "VNDB 上没找到",
                                  message: "没有找到和“\(title)”匹配的条目。可以改一下标题再试，或者用“搜索 VNDB…”手动选择。")
            }
        case .failure(let error):
            if !silent { report(error) }
        }
    }

    /// 用当前的 LLM 配置把简介翻成目标语言，流式显示，完成后存进资料里。
    func translateSynopsis(for id: UUID) {
        guard synopsisTranslating[id] == nil,
              let game = games.first(where: { $0.id == id }),
              let metadata = game.metadata, let synopsis = metadata.synopsis else { return }
        guard var translator = makeTranslator() else {
            alert = AlertItem(title: "还没配置翻译服务", message: "请先在设置的“翻译”页里添加一个 LLM 服务并填好 API Key。", settingsTab: .translation)
            return
        }
        translator.prompt = .synopsis(targetLanguage: settings.prompt.targetLanguage)
        let request = TranslationRequest(text: synopsis, glossary: metadata.synopsisGlossary(merging: game.translation.glossary))
        synopsisTranslating[id] = ""
        Task {
            defer { synopsisTranslating[id] = nil }
            do {
                let result = try await translator.translateStreaming(request) { partial in
                    Task { @MainActor [weak self] in
                        if self?.synopsisTranslating[id] != nil { self?.synopsisTranslating[id] = partial }
                    }
                }
                // 等待期间资料可能被刷新或解除关联。
                guard let i = games.firstIndex(where: { $0.id == id }), games[i].metadata?.synopsis == synopsis else { return }
                games[i].metadata?.synopsisTranslation = result
                saveGames()
            } catch {
                alert = AlertItem(title: "简介翻译失败", message: error.localizedDescription, settingsTab: .translation)
            }
        }
    }

    func unlinkVNDB(for id: UUID) {
        guard let i = games.firstIndex(where: { $0.id == id }) else { return }
        games[i].vndbID = nil
        games[i].metadata = nil
        saveGames()
    }

    // MARK: - 运行时

    func refreshRuntimes() {
        runtimes = WineRuntimeLocator.discover(paths: paths, customBinary: settings.customWineBinary)
    }

    var currentRuntime: WineRuntime? {
        runtimes.first { $0.wineBinary.path == settings.selectedRuntimePath } ?? runtimes.first
    }

    func installRuntime(from archive: URL) {
        let name = archive.lastPathComponent
            .replacingOccurrences(of: ".tar.xz", with: "")
            .replacingOccurrences(of: ".tar.gz", with: "")
            .replacingOccurrences(of: ".zip", with: "")
        busyMessage = "正在安装运行时 \(name)…"
        Task {
            defer { busyMessage = nil }
            do {
                let runtime = try await RuntimeInstaller.install(archive: archive, name: name, paths: paths)
                refreshRuntimes()
                settings.selectedRuntimePath = runtime.wineBinary.path
            } catch {
                report(error)
            }
        }
    }

    // MARK: - 启动

    /// 打包的原生引擎（ONScripter、krkr2）；开发时用仓库里构建好的。
    let nativeBinaries: [EngineKind: URL] = Dictionary(
        uniqueKeysWithValues: EngineKind.allCases.compactMap { e in NativeEngines.binary(for: e).map { (e, $0) } })
    /// 原生引擎跑不了的游戏和原因（KiriKiri 封包加了密等），自动模式下这些游戏用 Wine。
    var nativeUnsupported: [UUID: String] = [:]
    /// 这一次是自动模式选的原生引擎，失败了可以退回 Wine。
    @ObservationIgnored private var automaticNativeLaunches: Set<UUID> = []
    /// 用户手动停止的游戏，退出码不算失败。
    @ObservationIgnored private var stoppingGameIDs: Set<UUID> = []

    func backend(for game: Game) -> GameBackend {
        game.resolvedBackend(nativeAvailable: nativeBinaries[game.engine] != nil && nativeUnsupported[game.id] == nil)
    }

    /// 重新检查游戏能不能用原生引擎跑（导入、改引擎后调用）。
    func refreshNativeSupport(for game: Game) {
        guard nativeBinaries[game.engine] != nil else {
            nativeUnsupported[game.id] = nil
            return
        }
        Task {
            let reason = await Task.detached { NativeEngines.unsupportedReason(for: game) }.value
            nativeUnsupported[game.id] = reason
        }
    }

    func launch(_ game: Game) {
        if backend(for: game) == .native {
            launchNative(game)
            return
        }
        if SystemCheck.isAppleSilicon && !SystemCheck.isRosettaInstalled {
            alert = AlertItem(
                title: "需要安装 Rosetta 2",
                message: "Wine 是 x86_64 程序，在 Apple 芯片上需要 Rosetta 2。请在终端运行：\n\n\(SystemCheck.rosettaInstallCommand)"
            )
            return
        }
        guard let runtime = currentRuntime else {
            alert = AlertItem(title: "没有可用的 Wine 运行时", message: "请在设置的“运行环境”页里安装或指定一个 Wine 运行时。", settingsTab: .runtime)
            return
        }

        busyMessage = "正在准备“\(game.title)”的运行环境…"
        runningGameIDs.insert(game.id)
        Task {
            defer { busyMessage = nil }
            do {
                try await launcher.launch(game, runtime: runtime, cjkFont: settings.cjkFont) { [weak self] exit in
                    Task { @MainActor in self?.didExit(exit) }
                }
                if game.translation.enabled {
                    if game.translation.usesTextHook {
                        await startTextHook(for: game)
                    } else {
                        overlay.show(game: game)
                    }
                }
            } catch {
                runningGameIDs.remove(game.id)
                report(error)
            }
        }
    }

    private func launchNative(_ game: Game) {
        guard let engineName = NativeEngines.name(for: game.engine) else {
            alert = AlertItem(title: "没有对应的原生引擎",
                              message: "\(game.engine.displayName) 目前只能用 Wine 运行，请把“运行方式”改成 Wine。")
            return
        }
        guard let binary = nativeBinaries[game.engine] else {
            let reason = game.engine == .kirikiri && !SystemCheck.isAppleSilicon
                ? "krkr2 只支持 Apple 芯片的 Mac" : "这个 Kazusa 没有打包 \(engineName)"
            alert = AlertItem(title: "找不到 \(engineName)", message: "\(reason)，请把“运行方式”改成 Wine。")
            return
        }
        // 有 exe 才能退回 Wine（NScripter 游戏可能只有脚本）。
        let canFallBack = game.backend == nil && !game.executable.isEmpty
        runningGameIDs.insert(game.id)
        Task {
            do {
                let arguments = await Task.detached { NativeEngines.launchArguments(for: game) }.value
                if canFallBack { automaticNativeLaunches.insert(game.id) }
                let textSource = startNativeText(for: game)
                do {
                    try await launcher.launchNative(game, binary: binary, arguments: arguments,
                                                    extraEnvironment: textSource?.environment ?? [:]) { [weak self] exit in
                        Task { @MainActor in self?.didExit(exit) }
                    }
                } catch {
                    stopTextHook(for: game.id)
                    throw error
                }
                if game.translation.enabled {
                    if textSource != nil {
                        overlay.beginHook(game: game, nativePID: await launcher.processID(for: game.id))
                    } else {
                        overlay.show(game: game)
                    }
                }
            } catch {
                runningGameIDs.remove(game.id)
                report(error)
            }
        }
    }

    func stop(_ game: Game) {
        stoppingGameIDs.insert(game.id)
        stopTextHook(for: game.id)
        Task { await launcher.stop(game.id) }
    }

    private func didExit(_ exit: GameExit) {
        runningGameIDs.remove(exit.gameID)
        stopTextHook(for: exit.gameID)
        let wasAutomaticNative = automaticNativeLaunches.remove(exit.gameID) != nil
        let stoppedByUser = stoppingGameIDs.remove(exit.gameID) != nil
        guard let i = games.firstIndex(where: { $0.id == exit.gameID }) else { return }
        // 改用 Wine 再启动一次，并记住这个游戏用 Wine。
        if exit.shouldFallBackToWine(automaticNative: wasAutomaticNative, stoppedByUser: stoppedByUser) {
            let engineName = NativeEngines.name(for: games[i].engine) ?? "原生引擎"
            games[i].backend = .wine
            saveGames()
            alert = AlertItem(
                title: "\(engineName) 没能运行“\(games[i].title)”，已改用 Wine",
                message: "以后这个游戏都用 Wine 启动。想再试 \(engineName)，可以在游戏设置的“运行方式”里改回来。"
                    + "出错原因在游戏详情的“打开日志”里。"
            )
            launch(games[i])
            return
        }
        games[i].lastPlayedAt = exit.startedAt
        games[i].totalPlaySeconds += exit.duration
        saveGames()
        Task { await backUpAfterSession(games[i], since: exit.startedAt) }
        // 几秒内就退出且返回码非 0，多半是没跑起来，提示看日志。
        if exit.duration < 5 && exit.exitCode != 0 {
            alert = AlertItem(
                title: "“\(games[i].title)”很快就退出了",
                message: "返回码 \(exit.exitCode)。可以在游戏详情里点“打开日志”查看原因。"
            )
        }
    }

    func logFile(for game: Game) -> URL {
        paths.logsDir.appendingPathComponent("\(game.id.uuidString).log")
    }

    func prefixDriveC(for game: Game) -> URL {
        WinePrefix(name: game.prefixName, paths: paths).driveC
    }

    // MARK: - 存档备份

    /// 正在备份 / 恢复存档的游戏。
    var savesBusy: Set<UUID> = []

    /// 存档可能在前缀里的只有 Wine 游戏。
    private func saveDriveC(for game: Game) -> URL? {
        backend(for: game) == .wine ? prefixDriveC(for: game) : nil
    }

    func saveBackups(for game: Game) -> [SaveBackups.Backup] {
        paths.saveBackups(for: game.id).list()
    }

    func openBackupsFolder(for game: Game) {
        let dir = paths.saveBackups(for: game.id).directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    /// 游戏退出后：看这次改了哪些文件，记下存档位置；有改动就自动备份一次。全程静默，出错只写日志。
    private func backUpAfterSession(_ game: Game, since: Date) async {
        let directory = game.directory
        let driveC = saveDriveC(for: game)
        let modified = await Task.detached {
            SaveLocator.modifiedLocations(gameDirectory: directory, driveC: driveC, since: since)
        }.value
        guard !modified.isEmpty, let i = games.firstIndex(where: { $0.id == game.id }) else { return }
        let locations = Set(games[i].saveLocations ?? []).union(modified).sorted()
        if locations != games[i].saveLocations {
            games[i].saveLocations = locations
            saveGames()
        }
        savesBusy.insert(game.id)
        defer { savesBusy.remove(game.id) }
        do {
            try await paths.saveBackups(for: game.id).create(locations: locations, gameDirectory: directory,
                                                             driveC: driveC, kind: .automatic)
        } catch {
            appendLog("存档自动备份失败：\(error.localizedDescription)", for: game)
        }
    }

    func backUpSaves(for game: Game) {
        guard !savesBusy.contains(game.id) else { return }
        savesBusy.insert(game.id)
        Task {
            defer { savesBusy.remove(game.id) }
            do {
                try await paths.saveBackups(for: game.id).create(locations: game.saveLocations ?? [], gameDirectory: game.directory,
                                                                 driveC: saveDriveC(for: game), kind: .manual)
            } catch {
                alert = AlertItem(title: "没能备份存档", message: error.localizedDescription)
            }
        }
    }

    /// 用备份替换现在的存档。先把现在的存档备份一份（“恢复前”），恢复错了还能换回来。
    func restoreSaves(_ backup: SaveBackups.Backup, for game: Game) {
        guard !runningGameIDs.contains(game.id) else {
            alert = AlertItem(title: "游戏正在运行", message: "请先退出“\(game.title)”再恢复存档。")
            return
        }
        guard !savesBusy.contains(game.id) else { return }
        savesBusy.insert(game.id)
        Task {
            defer { savesBusy.remove(game.id) }
            let backups = paths.saveBackups(for: game.id)
            let driveC = saveDriveC(for: game)
            do {
                do {
                    try await backups.create(locations: game.saveLocations ?? [], gameDirectory: game.directory,
                                             driveC: driveC, kind: .beforeRestore)
                } catch SaveBackups.BackupError.nothingToBackUp {
                    // 现在没有存档，不用先备份。
                }
                try await backups.restore(backup, gameDirectory: game.directory, driveC: driveC)
                alert = AlertItem(title: "已恢复存档", message: "恢复前的存档也备份了一份（标着“恢复前”），需要时可以再换回来。")
            } catch {
                alert = AlertItem(title: "没能恢复存档", message: error.localizedDescription)
            }
        }
    }

    private func appendLog(_ message: String, for game: Game) {
        guard let handle = try? FileHandle(forWritingTo: logFile(for: game)) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("\n[Kazusa] \(message)\n".utf8))
    }

    // MARK: - 文本钩子

    /// 在游戏的前缀里启动文本钩子，钩到的文本交给字幕条翻译。失败时退回 OCR 悬浮窗。
    private func startTextHook(for game: Game) async {
        guard let context = await launcher.wineContext(for: game.id) else { return }
        overlay.beginHook(game: game)
        let host = TextHookHost()
        do {
            try host.start(game: game, runtime: context.runtime, environment: context.environment) { [weak self] event in
                Task { @MainActor in
                    guard let self else { return }
                    // 连上之后把这个游戏记下的特殊码再插一遍（读最新的，悬浮窗里可能刚加过）。
                    if case .ready = event {
                        for code in self.games.first(where: { $0.id == game.id })?.translation.hookCodes ?? [] {
                            host.insertHook(code)
                        }
                    }
                    self.overlay.handleHook(event, gameID: game.id)
                }
            }
            hookHosts[game.id] = host
        } catch {
            overlay.hookFailed(error.localizedDescription)
        }
    }

    /// 原生引擎自己输出台词（目前只有 ONScripter）：建好管道，引擎启动时把路径传过去。
    /// 不需要或建不了时返回 nil，改用 OCR 悬浮窗。
    private func startNativeText(for game: Game) -> NativeTextSource? {
        guard game.translation.enabled, game.translation.usesTextHook, NativeEngines.providesText(game.engine) else { return nil }
        do {
            let source = try NativeTextSource { [weak self] event in
                Task { @MainActor in self?.overlay.handleHook(event, gameID: game.id) }
            }
            nativeTextSources[game.id] = source
            return source
        } catch {
            appendLog("原生引擎的文本输出没能启动，改用 OCR：\(error.localizedDescription)", for: game)
            return nil
        }
    }

    private func stopTextHook(for id: UUID) {
        hookHosts.removeValue(forKey: id)?.stop()
        if let source = nativeTextSources.removeValue(forKey: id) {
            source.stop()
            overlay.handleHook(nil, gameID: id)
        }
    }

    /// 手动插入特殊码并记到游戏设置里，以后每次连上游戏都会自动插入。返回是否已发给正在运行的钩子。
    @discardableResult
    func insertHookCode(_ code: String, for id: UUID) -> Bool {
        if let i = games.firstIndex(where: { $0.id == id }) {
            var codes = games[i].translation.hookCodes ?? []
            if !codes.contains(code) {
                codes.append(code)
                games[i].translation.hookCodes = codes
                saveGames()
            }
        }
        guard let host = hookHosts[id] else { return false }
        host.insertHook(code)
        return true
    }

    /// 记住字幕条里手动指定的那一路；nil 表示回到自动选择。
    func rememberHookThread(_ key: HookThreadKey?, for id: UUID) {
        guard let i = games.firstIndex(where: { $0.id == id }), games[i].translation.hookThread != key else { return }
        games[i].translation.hookThread = key
        saveGames()
    }

    // MARK: - 翻译

    func makeTranslator() -> LLMTranslator? {
        guard let provider = settings.activeProvider else { return nil }
        return LLMTranslator(provider: provider, prompt: settings.prompt, apiKey: APIKeyStore.shared.apiKey(for: provider.id))
    }

    // MARK: - 错误

    func report(_ error: Error) {
        alert = AlertItem(title: "出错了", message: error.localizedDescription)
    }
}
