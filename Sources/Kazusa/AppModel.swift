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
    var coverSearch: CoverSearchRequest?

    var games: [Game] = []
    var selectedGameID: UUID?
    var runningGameIDs: Set<UUID> = []
    var runtimes: [WineRuntime] = []
    /// 正在进行的长操作（初始化前缀等），显示在界面上。
    var busyMessage: String?
    var alert: AlertItem?

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            do { try settings.save(to: paths.settingsFile) } catch { report(error) }
            overlay.settingsDidChange()
        }
    }

    @ObservationIgnored lazy var overlay = TranslatorOverlayController(model: self)

    struct CoverSearchRequest: Identifiable {
        let id: UUID
    }

    struct AlertItem: Identifiable {
        let id = UUID()
        var title: String
        var message: String
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
        loadCovers()
        for game in games where coverImages[game.id] == nil {
            autoFetchCover(for: game.id)
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
                self.saveGames()
            }
        )
    }

    private var placeholderGame: Game {
        Game(title: "", directory: URL(fileURLWithPath: "/"), executable: "", engine: .unknown, locale: .simplifiedChinese)
    }

    func saveGames() {
        do { try store.save(games) } catch { report(error) }
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
            let executable = isExe ? url.lastPathComponent : inspection.suggestedExecutable
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
            autoFetchCover(for: game.id)
        }
    }

    func remove(_ game: Game) {
        games.removeAll { $0.id == game.id }
        if selectedGameID == game.id { selectedGameID = nil }
        saveGames()
        covers.remove(for: game.id)
        coverImages[game.id] = nil
    }

    // MARK: - 封面

    private func loadCovers() {
        for game in games {
            if let data = covers.data(for: game.id), let image = NSImage(data: data) {
                coverImages[game.id] = image
            }
        }
    }

    /// 没有封面时自动找一张：先看游戏目录里有没有现成的图，再按标题查 VNDB。
    /// 静默进行，找不到或没网也不打扰用户。
    func autoFetchCover(for id: UUID) {
        guard let game = games.first(where: { $0.id == id }) else { return }
        let directory = game.directory
        let title = game.title
        Task {
            if let data = await Task.detached(operation: { LocalCoverFinder.find(in: directory) }).value {
                try? setCover(data, for: id)
                return
            }
            guard let entry = try? await VNDB.bestMatch(for: title) else { return }
            // 等待期间用户可能已经手动设置了封面。
            guard coverImages[id] == nil else { return }
            try? await applyCover(from: entry, to: id)
        }
    }

    /// 下载 VNDB 条目的封面并记下条目编号。
    func applyCover(from entry: VNDBEntry, to id: UUID) async throws {
        let data = try await VNDB.downloadImage(entry)
        try setCover(data, for: id)
        if let i = games.firstIndex(where: { $0.id == id }) {
            games[i].vndbID = entry.id
            saveGames()
        }
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

    func removeCover(for id: UUID) {
        covers.remove(for: id)
        coverImages[id] = nil
        if let i = games.firstIndex(where: { $0.id == id }), games[i].vndbID != nil {
            games[i].vndbID = nil
            saveGames()
        }
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

    func launch(_ game: Game) {
        if SystemCheck.isAppleSilicon && !SystemCheck.isRosettaInstalled {
            alert = AlertItem(
                title: "需要安装 Rosetta 2",
                message: "Wine 是 x86_64 程序，在 Apple 芯片上需要 Rosetta 2。请在终端运行：\n\n\(SystemCheck.rosettaInstallCommand)"
            )
            return
        }
        guard let runtime = currentRuntime else {
            alert = AlertItem(title: "没有可用的 Wine 运行时", message: "请在“设置 → 运行环境”里安装或指定一个 Wine 运行时。")
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
                    overlay.show(game: game)
                }
            } catch {
                runningGameIDs.remove(game.id)
                report(error)
            }
        }
    }

    func stop(_ game: Game) {
        Task { await launcher.stop(game.id) }
    }

    private func didExit(_ exit: GameExit) {
        runningGameIDs.remove(exit.gameID)
        guard let i = games.firstIndex(where: { $0.id == exit.gameID }) else { return }
        games[i].lastPlayedAt = exit.startedAt
        games[i].totalPlaySeconds += exit.duration
        saveGames()
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

    // MARK: - 翻译

    func makeTranslator() -> LLMTranslator? {
        guard let provider = settings.activeProvider else { return nil }
        return LLMTranslator(provider: provider, prompt: settings.prompt, apiKey: Keychain.apiKey(for: provider.id))
    }

    // MARK: - 错误

    func report(_ error: Error) {
        alert = AlertItem(title: "出错了", message: error.localizedDescription)
    }
}
