# 架构检查 2026-11-10（UI 以外）

范围：KazusaCore、AppModel、悬浮翻译控制器、kazusa-cli。`swift test` 87 个测试全部通过。

热点（30 天内的改动次数 / 行数）：AppModel.swift 15 次 / 705 行，TranslatorOverlay.swift 8 次 / 802 行，GameLauncher.swift 8 次 / 173 行。

---

## 1. 游戏退出时先清掉会话，再通知调用方  [Strong]

Files: Sources/KazusaCore/Wine/GameLauncher.swift:140-152, Sources/Kazusa/AppModel.swift:488-505
Signal: 两个 Task 之间有竞态，退回 Wine 这条路径会撞上
Problem: `terminationHandler` 先发出 `Task { await self?.didExit(gameID) }`，紧接着调用 `onExit`。AppModel 的 `didExit` 在“原生引擎很快就崩溃了”时会马上调 `launch(games[i])`，这又会进 `launcher.launch`。launcher 在第一行就检查 `sessions[game.id] == nil`。这两个 Task 谁先跑没有保证。如果主线程这条先跑到，就会抛出“游戏已经在运行”，用户看到的是一个错误，而不是改用 Wine 启动。
Proposal:
```swift
process.terminationHandler = { [weak self] p in
    try? log.close()
    let exit = GameExit(...)
    Task {
        await self?.didExit(gameID)   // 先清会话
        onExit(exit)                   // 再通知
    }
}
```
Benefits: 改的只是 `GameLauncher` 里一处顺序，调用方不用动。`onExit` 原本就是“在任意线程”调用，契约不变。
Proof of same behavior: 补一个测试：用 `/usr/bin/false` 作为原生 binary 调 `launchNative`，在 `onExit` 里立刻再调一次 `launchNative`，断言不会抛 `alreadyRunning`。
Plan: 一个提交（修改 + 测试）。

## 2. 输入框不再每敲一个字就写一次磁盘或钥匙串  [Strong]

Files: Sources/Kazusa/AppModel.swift:43-47, :112-122；Sources/Kazusa/Views/SettingsView.swift:209, :250-256
Signal: 主线程上有慢操作
Problem:
- `binding(for:)` 的 setter 每次都调 `saveGames()`。游戏设置里改标题、术语表或启动参数时，每敲一个字都会在主线程把整个游戏库编码成 JSON 再写盘。
- `settings` 的 didSet 每个字都写 settings.json，还会调用 `overlay.settingsDidChange()`。提示词编辑器就是这样。
- API Key 的 `onChange` 每个字都执行 `SecItemDelete` + `SecItemAdd`，再通知悬浮窗换一个翻译器。粘贴还好，手打一个 50 位的 Key 就是 100 次钥匙串操作。
Proposal: 内存里的状态照常立刻改，只把写盘的部分合并起来：
```swift
@ObservationIgnored private var saveGamesTask: Task<Void, Never>?
func scheduleSaveGames() {
    saveGamesTask?.cancel()
    saveGamesTask = Task { try? await Task.sleep(for: .milliseconds(400)); if !Task.isCancelled { saveGames() } }
}
```
`binding(for:)` 改调 `scheduleSaveGames()`，settings 照此处理。退出程序时（目前还没有 `applicationWillTerminate`，需要新加一个 `NSApplicationDelegateAdaptor` 或监听 `NSApplication.willTerminateNotification`）把还没写的保存立刻写掉。API Key 改成在 `onSubmit` 和离开页面时保存。
Benefits: 打字不卡；钥匙串只写一次。
Proof of same behavior: 改完、等 0.5 秒、退出、重开，改动都还在；用“退出前立刻 ⌘Q”检查挂着的保存有没有被写掉。
Plan: 1) 游戏库合并保存 + 退出前写掉；2) settings 合并保存；3) API Key 改为提交时保存。

## 3. 把“原生引擎失败后退回 Wine”的规则移进 KazusaCore  [Worth exploring]

Files: Sources/Kazusa/AppModel.swift:488-505
Signal: 纯逻辑留在 `@MainActor` 的 store 里，测试编不到
Problem: 退回 Wine 的条件（自动选择的原生引擎、不是用户停止的、返回码非 0、运行不到 60 秒）写在 `didExit` 里面，测试目标碰不到它。后端选择 `resolvedBackend` 早就移进了 Core 而且有测试，这一条是漏掉的。
Proposal:
```swift
extension GameExit {
    /// 自动选择的原生引擎一启动就失败：改用 Wine。
    public func shouldFallBackToWine(automaticNative: Bool, stoppedByUser: Bool) -> Bool {
        automaticNative && !stoppedByUser && exitCode != 0 && duration < 60
    }
}
```
Benefits: 60 秒、返回码这些边界值可以写成表格测试；`didExit` 少一个分支。
Proof of same behavior: 新测试覆盖四个条件，`didExit` 只换成调用这个函数。
Plan: 一个提交。

## 4. 打开翻译记录、读封面不在主线程上进行  [Worth exploring]

Files: Sources/Kazusa/Overlay/TranslatorOverlay.swift:187, Sources/KazusaCore/Translation/TranslationSession.swift:25-30, Sources/Kazusa/AppModel.swift:192-198
Signal: 主线程上有 I/O
Problem:
- `TranslationSession.init` 是同步的 nonisolated 初始化，会把整个 JSONL 记录文件读进来再逐行解码。它是在 `@MainActor` 的控制器里构造的，所以这些都跑在主线程。记录文件只增不减，玩得越久，打开悬浮窗越卡。
- `loadCovers()` 在 AppModel 初始化时把每张封面同步读进内存。
Proposal: 让 `TranslationSession` 先建一个空会话，再提供 `func restore() async` 在 actor 上加载（控制器已经在用 `Task { state.lines = await session.lines }`，只需在它前面加一行 `await session.restore()`）。封面在 `Task.detached` 里读完 Data，再回主线程建 `NSImage`。
Benefits: 打开悬浮窗、启动程序不再随数据量变慢。
Proof of same behavior: 现有 TranslatorTests 里的会话测试全部通过；加一个测试：先 `restore()` 再 `submit` 同一句，命中缓存，不调用 transport。
Plan: 1) 会话改为异步恢复；2) 封面在后台读取。

## 5. 把悬浮翻译控制器拆成单独的文件  [Speculative]

Files: Sources/Kazusa/Overlay/TranslatorOverlay.swift（802 行：控制器约 430 行，加上状态、视图和 NSPanel 子类）
Signal: 文件超过 600 行
Problem: 改 OCR 轮询或钩子管线的时候，要在视图代码中间翻找。
Proposal: 原样搬到 `TranslatorOverlayController.swift`，不改任何代码。
Benefits: 改动更集中，diff 更好读。
Proof of same behavior: 编译通过就行（纯移动）。
Plan: 一个提交。

---

## 首选

**先做 1 和 2。** 1 是一个真实存在的竞态，用户能碰到，修起来只要几行，还能顺便给 `GameLauncher` 补上第一个测试。2 修的是打字时卡顿和钥匙串被反复写入，每个人每天都在碰的路径。

## 考虑过、不建议做

- **把 AppModel 拆成几个按功能划分的 store**（游戏库、运行时、启动、翻译）。705 行确实大，但它是唯一一个跟 UI 打交道的地方，跨功能的调用很多（启动 → 文本钩子 → 悬浮窗 → 备份）。拆开以后这些调用会变成 store 之间互相引用，加功能反而要改更多文件。等它超过 1000 行，或者某个功能需要单独测试时再拆。做完 1–4 以后它会变小一点。
- **在 `launch()` 里再加一层防止重复启动**：`runningGameIDs` 是同步插入的，按钮也会禁用，`GameLauncher` 还有 `alreadyRunning` 检查。已经够了。
- **给 Keychain、ProcessRunner 加协议方便替换**：只有一个实现，也没有测试要替换它们。翻译层已经有 `HTTPTransport` 这个真正有用的接缝。
- **自动 OCR（1.2 秒）和剪贴板（0.4 秒）轮询**：只在悬浮窗打开、选了对应模式时才运行，耗电可以接受；剪贴板已经先比较 `changeCount`，内容变了才读取。
- **移除正在运行的游戏时先停止它**：游戏退出时 `didExit` 会自己找不到这条记录然后返回，钩子也会在那时停掉。确认对话框已经说清楚了后果。可以顺手在 `remove()` 里调 `stop()`，但不急。

---

## 结果

1–5 都已完成，每项一个提交：dc1a1c8、0dbae4a、9b37dd2、db1ea06，以及搬移控制器的提交。

- 1：竞态在旧代码上没能复现（8 次都通过），修改把先后顺序从“通常如此”变成有保证。新测试是契约测试。
- 2：实机验证过：改标题后 0.1 秒退出程序，library.json 里是新标题。
- 4：会话不改接口，第一次用到 `lines`/`submit` 时才读取记录。
