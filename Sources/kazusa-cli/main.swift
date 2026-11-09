// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation
import KazusaCore

let usage = """
用法：kazusa-cli <命令>

  runtimes                          列出找到的 Wine 运行时
  install-runtime <压缩包> [名字]     安装 Wine 运行时到 Runtimes/
  inspect <游戏目录>                 识别引擎、主程序和区域
  run <游戏目录或 exe> [--locale ja|zhs|zht] [--prefix 名字] [--debug]
                                    启动游戏并等待退出（日志输出到终端）
  wine [--locale ...] [--prefix ...] <参数...>
                                    在前缀里执行任意 wine 命令（如 winecfg）
  cover <标题>                       在 VNDB 上搜索封面（只打印结果，不下载）
  info <VNDB 编号或标题> [--translate]
                                    从 VNDB 拉取简介、品牌等资料并打印；--translate 用设置里的 LLM 翻译简介
"""

let paths = KazusaPaths.default
var args = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("错误：\(message)\n".utf8))
    exit(1)
}

@MainActor func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

@MainActor func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

func parseLocale(_ s: String?) -> GameLocale? {
    switch s {
    case nil: nil
    case "ja": .japanese
    case "zhs", "zh": .simplifiedChinese
    case "zht": .traditionalChinese
    default: fail("未知区域 \(s!)，可选 ja / zhs / zht")
    }
}

func requireRuntime() -> WineRuntime {
    guard let runtime = WineRuntimeLocator.discover(paths: paths).first else { fail("没有找到 Wine 运行时，先 install-runtime") }
    return runtime
}

guard !args.isEmpty else { print(usage); exit(0) }
let command = args.removeFirst()

do {
switch command {
case "runtimes":
    for runtime in WineRuntimeLocator.discover(paths: paths) {
        print("\(runtime.displayName)\t\(await runtime.version() ?? "?")\t\(runtime.wineBinary.path)")
    }

case "install-runtime":
    guard let archive = args.first else { fail("缺少压缩包路径") }
    let url = URL(fileURLWithPath: archive)
    let name = args.count > 1 ? args[1] : url.lastPathComponent.components(separatedBy: ".tar").first!
    print("正在安装 \(name)…")
    let runtime = try await RuntimeInstaller.install(archive: url, name: name, paths: paths)
    print("✅ \(runtime.wineBinary.path)  \(await runtime.version() ?? "")")

case "inspect":
    guard let dir = args.first else { fail("缺少游戏目录") }
    let r = GameInspector.inspect(directory: URL(fileURLWithPath: dir))
    print("标题：\(r.title)")
    print("引擎：\(r.engine.engine.displayName)（置信度 \(r.engine.confidence)）依据：\(r.engine.evidence.joined(separator: ", "))")
    print("区域：\(r.suggestedLocale.displayName)")
    print("主程序候选：")
    for exe in r.executableCandidates.prefix(8) { print("  \(exe)") }

case "run":
    let locale = parseLocale(option("--locale"))
    let prefixName = option("--prefix")
    let debug = flag("--debug")
    guard let target = args.first else { fail("缺少游戏目录或 exe") }
    let url = URL(fileURLWithPath: target)
    let isExe = url.pathExtension.lowercased() == "exe"
    let dir = isExe ? url.deletingLastPathComponent() : url
    let inspection = GameInspector.inspect(directory: dir)
    guard let exe = isExe ? url.lastPathComponent : inspection.suggestedExecutable else { fail("没有找到 exe") }
    var game = Game(title: inspection.title, directory: dir, executable: exe,
                    engine: inspection.engine.engine, locale: locale ?? inspection.suggestedLocale)
    if let prefixName { game.prefixName = prefixName }
    if debug { game.environment["WINEDEBUG"] = "err+all,fixme-all" }
    let runtime = requireRuntime()
    print("引擎 \(game.engine.displayName) · 区域 \(game.locale.displayName) · 前缀 \(game.prefixName)")
    print("运行时 \(runtime.wineBinary.path)")
    print("启动 \(game.executable)…（首次会初始化前缀，需要一两分钟）")

    let launcher = GameLauncher(paths: paths)
    let exit: GameExit = try await withCheckedThrowingContinuation { continuation in
        Task {
            do {
                try await launcher.launch(game, runtime: runtime, cjkFont: "") {
                    continuation.resume(returning: $0)
                }
                print("日志：\(await launcher.logFile(for: game.id).path)")
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    print("退出码 \(exit.exitCode)，运行 \(Int(exit.duration)) 秒")
    if let log = try? String(contentsOf: exit.logFile, encoding: .utf8) {
        print("---- 日志末尾 ----")
        print(log.split(separator: "\n", omittingEmptySubsequences: false).suffix(40).joined(separator: "\n"))
    }

case "wine":
    let locale = parseLocale(option("--locale")) ?? .japanese
    let prefixName = option("--prefix") ?? locale.defaultPrefixName
    let runtime = requireRuntime()
    _ = try await RosettaWoW64Fix.applyToRuntime(runtime, paths: paths)
    let prefix = WinePrefix(name: prefixName, paths: paths)
    try await prefix.prepare(runtime: runtime, locale: locale, cjkFont: "")
    _ = try await RosettaWoW64Fix.applyToPrefix(prefix.url, runtime: runtime, paths: paths)
    let env = WineEnvironment.make(runtime: runtime, prefix: prefix.url, locale: locale, extra: ["WINEDEBUG": "err+all,fixme-all"])
    let result = try await ProcessRunner.run(runtime.wineBinary, arguments: args, environment: env)
    print(result.output)
    exit(result.exitCode)

case "cover":
    let title = args.joined(separator: " ")
    guard !title.isEmpty else { fail("需要游戏标题") }
    for query in VNDB.searchQueries(for: title) {
        print("搜索：\(query)")
        for entry in try await VNDB.search(query, results: 5) {
            let mark = entry.hasSafeImage ? "✓" : "✗"
            print("  \(mark) \(entry.id)  \(entry.displayTitle)  \(entry.released ?? "")  \(entry.imageURL?.absoluteString ?? "无图")")
        }
    }

case "info":
    let translate = flag("--translate")
    let query = args.joined(separator: " ")
    guard !query.isEmpty else { fail("需要 VNDB 编号（如 v3144）或游戏标题") }
    var id = query
    if query.range(of: #"^v\d+$"#, options: .regularExpression) == nil {
        guard let entry = try await VNDB.bestMatch(for: query, requireSafeImage: false) else { fail("VNDB 上没找到“\(query)”") }
        id = entry.id
    }
    let m = try await VNDB.details(id: id)
    print("编号：\(m.vndbID)")
    if let t = m.originalTitle { print("原名：\(t)") }
    if let t = m.chineseTitle { print("中文名：\(t)") }
    if !m.developers.isEmpty { print("品牌：\(m.developers.joined(separator: "、"))") }
    if let t = m.releasedText { print("发售：\(t)") }
    if let t = m.lengthText { print("游玩时长：\(t)") }
    if let t = m.ratingText { print("评分：\(t)") }
    if let t = m.synopsis { print("\n\(t)") }
    if translate, let synopsis = m.synopsis {
        let settings = AppSettings.load(from: paths.settingsFile)
        guard let provider = settings.activeProvider else { fail("设置里还没有 LLM 接口") }
        let translator = LLMTranslator(provider: provider, prompt: .synopsis(targetLanguage: settings.prompt.targetLanguage),
                                       apiKey: Keychain.apiKey(for: provider.id))
        print("\n—— 译文（\(provider.name) / \(provider.model)）——")
        print(try await translator.translate(TranslationRequest(text: synopsis, glossary: m.synopsisGlossary(merging: [:]))))
    }

default:
    print(usage)
    exit(1)
}
} catch {
    fail(error.localizedDescription)
}
