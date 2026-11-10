# 参与贡献

感谢你愿意帮 Kazusa 变得更好！反馈问题、测兼容性、改代码都很欢迎。

- [反馈问题](#反馈问题)
- [开发环境](#开发环境)
- [代码结构](#代码结构)
- [代码规范](#代码规范)
- [提交与 Pull Request](#提交与-pull-request)
- [版权与素材](#版权与素材)

## 反馈问题

请从 [New issue](https://github.com/Shizuku11451/kazusa/issues/new/choose) 里选对应的模板：

| 模板 | 用于 |
|---|---|
| **游戏兼容性问题** | 游戏打不开、乱码、黑屏、崩溃、钩不到台词 |
| **Bug** | Kazusa 自身的问题：界面、游戏库、翻译、设置 |
| **功能建议** | 想要的新功能或改进 |

兼容性问题请附上**日志**（详情页右上角 ⋯ → 打开日志），并写明游戏名（最好附 VNDB 链接）、版本（原版 / 汉化版）、引擎和 Wine 版本。日志里如果有你不想公开的路径或用户名，贴出来之前先删掉。

## 开发环境

需要 macOS 14+ 和 Swift 6。只装 Command Line Tools 就够，不需要 Xcode。

```bash
git clone https://github.com/Shizuku11451/kazusa.git
cd kazusa
swift run Kazusa            # 直接运行
scripts/test.sh             # 跑单元测试（会自动处理只装 CLT 时的 Testing 框架路径）
scripts/build-app.sh        # 打包到 build/Kazusa.app（通用二进制）
scripts/make-dmg.sh         # 把 build/Kazusa.app 做成 dmg 安装包
swift run kazusa-cli        # 命令行工具：安装运行时、识别游戏、不开界面直接启动
```

**用独立的数据目录。** 设置 `KAZUSA_HOME=/tmp/kazusa-dev`，开发时就不会动到你自己的游戏库。默认数据放在 `~/Library/Application Support/Kazusa/`（`library.json`、`settings.json`、`Prefixes/`、`Runtimes/`、`Logs/`、`Covers/` 等）。

**签名和屏幕录制权限。** `build-app.sh` 默认用 ad-hoc 签名。这种签名下，macOS 按每次构建的程序指纹记录屏幕录制权限，重新构建后就要重新授权。解决办法是建一个自签名的代码签名证书，取名 `Kazusa Local Signing`（钥匙串访问 → 证书助理 → 创建证书，证书类型选“代码签名”）。脚本找到这个证书就会用它签名，之后重新构建，权限也一直有效。也可以用 `KAZUSA_SIGN_IDENTITY` 指定别的证书。

**第三方组件。** ONScripter、krkr2、LunaHook、`wow64cpu.dll` 都已经预编译好，放在 `ThirdParty/` 下。只有修改它们时才需要重新编译，方法见各自目录里的 README。`HookHost/` 是在 Wine 里运行的 C 小程序，用 mingw-w64 编译（见 `HookHost/build.sh`）。

## 代码结构

```
Sources/
  KazusaCore/              # 与界面无关的核心逻辑，带单元测试
    Engine/                # 引擎识别、主程序打分、区域猜测
    Wine/                  # 运行时发现与安装、前缀、环境变量、启动
    Native/                # 原生引擎（ONScripter、krkr2）
    TextHook/              # 文本钩子：PE 位数、事件解析、文本清理、挑对白那一路
    Translation/           # LLM 配置、请求构造与解析、翻译会话
    Covers/                # 封面缓存、目录内找图、VNDB 查询
    Saves/                 # 存档定位与备份恢复
    Models/ Library/ Settings/ Support/
  Kazusa/                  # SwiftUI 应用
    Views/                 # 游戏库、详情、设置
    Overlay/               # 翻译悬浮窗 / 字幕条（NSPanel）
    Capture/               # ScreenCaptureKit 截图 + Vision OCR
  kazusa-cli/              # 开发用命令行
HookHost/                  # kazusa-hook32/64.exe：在 Wine 里加载 LunaHost、注入游戏、按行输出 JSON
ThirdParty/                # 第三方组件的源码补丁、构建脚本和预编译产物
Tests/KazusaCoreTests/     # 单元测试（Swift Testing）
```

## 代码规范

### 分层

- **业务逻辑放进 `KazusaCore`。** `KazusaCore` 不引入 SwiftUI 和 AppKit，不碰界面状态，这样才能单元测试、才能给命令行工具复用。`Kazusa`（应用层）只负责界面和把调用接起来。
- 纯逻辑（解析、打分、路径计算、规则判断）尽量写成不依赖网络和文件系统的函数，比如 `VNDB.parseDetails(_:)` 只吃 `Data`，网络请求另外包一层。这样测试时直接喂样例数据就行。
- 先找现成的工具和写法再动手。比如 JSON 读写用 `JSONFile`（在 `Support/Paths.swift` 里），跑子进程用 `Wine/ProcessRunner`。

### Swift

- **Swift 6 严格并发**，不要关掉检查。`@unchecked Sendable` 和 `nonisolated(unsafe)` 只在确实自己加了锁或串行队列时使用，并在旁边注释说明为什么线程安全。界面状态放在 `@MainActor` 的 `AppModel` 里，耗时工作用 `Task.detached` 或 actor 移出主线程。
- 状态用 `@Observable`，不用 `ObservableObject`。
- 4 个空格缩进；一行尽量不超过 130 个字符。
- 能用标准库和系统框架解决的，不引入第三方 Swift 包。目前项目**没有任何** SwiftPM 依赖，新增依赖要在 PR 里说明理由。
- 写入 `library.json` / `settings.json` 的模型要**向后兼容**：新字段用可选类型或带默认值，确保旧版本存的文件还能读。最好补一个“读旧数据”的测试（参考 `decodesOldLibraryWithoutMetadata`）。
- 会丢数据的操作（删除、覆盖、迁移）要先确认新数据写成功了，再删旧的。

### 注释和文案

- 代码注释用**中文**，写“为什么”，不复述代码做了什么。公开类型和方法用 `///` 写一句话说明。
- 已知限制、留待以后改进的捷径，用这个格式标出来，方便以后找：
  ```swift
  // shortcut: <限制是什么>，<什么时候该升级>
  ```
- 界面文案用简体中文，说人话：告诉用户发生了什么、下一步该做什么。避免“错误 -1”“操作失败”这类空话；技术细节放进日志，不要堆在界面上。

### 文件头

每个 Swift 和 C 源文件开头都要有许可证声明：

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451
```

### 测试

- 测试用 **Swift Testing**（`@Test`、`#expect`、`#require`），不用 XCTest。
- `KazusaCore` 里的新逻辑要带测试，特别是解析、规则判断和边界情况。改 bug 时先写一个能复现问题的测试。
- 测试不访问网络，也不依赖本机装的 Wine 或游戏；需要文件时在临时目录里现造（参考 `XP3Builder`）。
- 提交前跑一遍 `scripts/test.sh`。CI 会在 macOS 上执行构建、测试和打包。

### 隐私和网络

- 对外只发必要的数据：VNDB 只发标题和条目编号；翻译文本只发给用户自己配置的 LLM 服务。
- 不加统计、遥测或崩溃上报。
- API Key 等密钥不能写进日志、`settings.json` 或错误提示。

## 提交与 Pull Request

- 从 `main` 切分支开发，一个 PR 只做一件事。
- 提交信息用中文，格式是 `模块：做了什么`。标题行说清楚改了什么、修了什么现象，需要时在正文里写原因：
  ```
  封面飞行：连点时新的飞行不起飞、封面卡在半路——onAppear 移到 id 前面
  API Key 改存 apikeys.json（600 权限），不再每次更新都要钥匙串密码
  ```
- 改了界面的话，PR 里附截图或录屏（不要露出受版权保护的游戏画面，见下文）。
- 修兼容性问题时，写明在哪个游戏、哪个 Wine 版本、哪个 macOS 版本上验证过。
- 改动较大（新模块、新依赖、改数据格式）时，建议先开 issue 讨论方向。

## 版权与素材

- 提交代码即表示你同意以 [GPL-3.0-or-later](LICENSE) 授权你的贡献。
- **不要提交**游戏文件、游戏截图、立绘、音频，或其他受版权保护的素材。测试需要游戏数据时，用代码现造最小样例。
- 引入第三方代码或二进制时，放在 `ThirdParty/<名字>/` 下，附上来源、版本、构建方法和许可证，并更新 README 的“第三方组件”一节。许可证必须和 GPL-3.0 兼容。
- Kazusa 不提供、也不会接入任何游戏下载渠道，请只运行你合法拥有的游戏。
