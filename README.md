# Kazusa

[![CI](https://github.com/Shizuku11451/kazusa/actions/workflows/ci.yml/badge.svg)](https://github.com/Shizuku11451/kazusa/actions/workflows/ci.yml)

在 Mac 上玩 Windows galgame 的原生启动器：**汉化版开箱即玩**，**日文原版配 LLM 实时翻译**。

- 纯 SwiftUI + Swift Package，没有用 CrossOver / Whisky 等现有前端；唯一的外部依赖是 Wine 本身（作为 Windows 兼容层）。
- 运行时管理、前缀、转区、字体替换、启动、OCR 和翻译都是自己写的。

![游戏库](docs/screenshots/library.png)

<sub>截图里的游戏都是虚构的演示数据。</sub>

## 功能（MVP）

| 模块 | 说明 |
|---|---|
| 游戏库 | 拖入文件夹或 exe 即可导入。自动识别引擎（KiriKiri、NScripter、Ren'Py、Unity 等 15 种）和主程序，并按文件名判断是汉化版还是日文原版 |
| 转区 | 每个游戏可选 简中 / 繁中 / 日文 区域，对应 `zh_CN` / `zh_TW` / `ja_JP` 的 locale，每种区域共用一个 Wine 前缀 |
| 字体 | 按区域把 MS Gothic、SimSun 等替换成 macOS 自带字体（日文用ヒラギノ角ゴシック，中文用冬青黑体），并配置字体链接，菜单和对话框也不会出方块字 |
| 运行时 | 自动发现 Wine（/Applications、Homebrew），也可以从 `.tar.xz` 导入到 Kazusa 自己的 Runtimes 目录 |
| 翻译悬浮窗 | 半透明取景框盖在游戏文本框上，用 ScreenCaptureKit 截图、Vision 做 OCR，再交给 LLM 翻译。三种模式：手动、自动（画面稳定后才翻译）、剪贴板。系统级快捷键 ⇧⌘R 识别、⇧⌘L 锁定（点击穿透到游戏），游戏在前台也能用；按游戏记住悬浮窗位置；译文流式输出 |
| 自定义 LLM | 支持 OpenAI 兼容接口（DeepSeek、Ollama、LM Studio、各类中转）和 Anthropic 接口；会带上前文和每个游戏的术语表；API Key 存在钥匙串里 |

## 构建

需要 macOS 14+ 和 Swift 6（装 Command Line Tools 就够，不需要 Xcode）。

```bash
swift run Kazusa            # 开发时直接运行
scripts/build-app.sh        # 打包到 build/Kazusa.app
scripts/test.sh             # 跑单元测试（会自动处理只装了 CLT 时的 Testing 框架路径）
swift run kazusa-cli        # 开发用命令行：安装运行时、识别游戏、不开界面直接启动游戏
```

## 运行游戏前的准备

1. **Rosetta 2**（Apple 芯片）：`softwareupdate --install-rosetta --agree-to-license`
2. **Wine**：从 [Gcenx/macOS_Wine_builds](https://github.com/Gcenx/macOS_Wine_builds/releases) 下载 `wine-staging-*-osx64.tar.xz`，在 设置 → 运行环境 → 从压缩包安装（或 `swift run kazusa-cli install-runtime <压缩包>`）。
   > Homebrew 的 `wine-stable` / `wine@staging` cask 因为过不了 Gatekeeper 检查，已在 2026-09-01 被禁用。
3. 用 OCR 翻译时需要**屏幕录制权限**：系统设置 → 隐私与安全性 → 屏幕与系统录音

## 代码结构

```
Sources/
  KazusaCore/              # 与 UI 无关的核心逻辑，全部有单元测试
    Engine/                # 引擎识别、主程序打分、区域猜测
    Wine/                  # 运行时发现与安装、前缀、环境变量、启动器
    Translation/           # LLM 配置、请求构造与解析、翻译会话（去重、上文、缓存）
    Models/ Library/ Settings/ Support/
  Kazusa/                  # SwiftUI 应用
    Views/                 # 游戏库、详情、设置
    Overlay/               # 翻译悬浮窗（NSPanel）
    Capture/               # ScreenCaptureKit 截图 + Vision OCR
```

数据存放在 `~/Library/Application Support/Kazusa/`，包括 `library.json`、`settings.json`、`Prefixes/`、`Runtimes/`、`Logs/`。

## 路线图

- [ ] **原生后端**：KiriKiri 走 krkrsdl2，NScripter 走 ONScripter，System4 走 xsystem4。这些游戏可以完全不用 Wine
- [ ] **文本钩子**：自己实现 Textractor 式的 hook，直接从游戏进程里取文本，比 OCR 更准；剪贴板模式现在可以先搭配外部工具使用
- [ ] 视频解码：给前缀装 LAV/quartz 一类的方案，解决 OP/ED 黑屏
- [ ] 从 VNDB 拉取封面和元数据
- [x] 全局快捷键（游戏在前台时也能触发识别）、悬浮窗点击穿透
- [ ] 每个游戏独立前缀、存档备份
- [x] 流式翻译输出
- [ ] 翻译结果持久化

## 许可证

Kazusa 以 [GNU 通用公共许可证 v3.0 或更高版本](LICENSE)（GPL-3.0-or-later）发布。

Copyright (C) 2026 Shizuku11451

你可以自由使用、修改和再分发本程序。但分发修改版或基于它的作品时，必须同样以 GPL-3.0 或更高版本公开源代码。

### 第三方组件

Kazusa **不打包、不链接**下列组件，只在运行时把它们作为独立程序调用，或使用系统自带的部分：

| 组件 | 许可证 | 使用方式 |
|---|---|---|
| [Wine](https://www.winehq.org/) | LGPL-2.1-or-later | 用户自行安装，或从压缩包导入；作为子进程调用 |
| Rosetta 2 | Apple 专有 | macOS 系统组件，由用户通过 `softwareupdate` 安装 |
| SwiftUI / ScreenCaptureKit / Vision / Security | Apple SDK | 系统框架 |
| 冬青黑体等系统字体 | Apple 专有 | 只在 Wine 注册表里引用字体名，不分发字体文件 |

翻译功能会把识别到的文本发给**用户自己配置**的 LLM 服务，请遵守对应服务的使用条款。

### 贡献

提交代码即表示你同意以 GPL-3.0-or-later 授权你的贡献。请不要提交任何游戏文件、游戏截图或其他受版权保护的素材。

- 遇到游戏打不开、乱码、黑屏，请用「游戏兼容性问题」模板提 issue，附上详情页里的日志。
- 开发时可以设置 `KAZUSA_HOME=/tmp/kazusa-dev` 使用独立的数据目录，不影响自己的游戏库。
- `swift run kazusa-cli` 可以不开界面直接测试运行时、游戏识别和启动。
