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
| 封面 | 导入时自动获取：先找游戏目录里的 cover / package 等图片，没有就按标题（会去掉“HD版”“汉化版”、版本号等修饰）查 [VNDB](https://vndb.org)，只自动采用非成人的封面。也可以右键“搜索封面…”手动挑选，或者把图片拖到详情页。联网时只会把游戏标题发送给 api.vndb.org |
| 资料 | 匹配到 VNDB 条目后自动拉取中文名、原名、品牌、发售日、平均游玩时长、评分和简介（去掉剧透段落）。用目录里的图当封面的游戏也会按标题匹配一次；匹配错了可以在详情页解除关联或手动搜索。VNDB 的简介大多是英文，可以一键用设置里的 LLM 翻成中文（流式显示，译文会保存，可切回原文） |
| 原生运行 | NScripter 游戏默认用打包的 [ONScripter](ThirdParty/onscripter-yuri/)（OnscripterYuri）直接运行，不需要 Wine 和 Rosetta：自动判断脚本编码（Shift-JIS / GBK / UTF-8），按区域选系统字体，存档仍在游戏目录。在游戏的“设置”里可以把“运行方式”改回 Wine |
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
   > 较新的 macOS（已确认 27.x）上 Rosetta 处理 WoW64 模式切换有 bug，32 位游戏会随机崩溃或卡死。Kazusa 启动游戏时会自动给托管的运行时和前缀换上修复版 `wow64cpu.dll`（目前预编译了 Wine 11.21 的），详见 [ThirdParty/wow64cpu-rosetta](ThirdParty/wow64cpu-rosetta/README.md)。
   > NScripter 游戏默认用打包的 ONScripter 运行，不需要前两步。
3. 用 OCR 翻译时需要**屏幕录制权限**：系统设置 → 隐私与安全性 → 屏幕与系统录音

## 代码结构

```
Sources/
  KazusaCore/              # 与 UI 无关的核心逻辑，全部有单元测试
    Engine/                # 引擎识别、主程序打分、区域猜测
    Wine/                  # 运行时发现与安装、前缀、环境变量、启动器
    Native/                # 原生引擎（ONScripter）：查找、脚本编码、字体、启动参数
    Covers/                # 封面缓存、游戏目录内找图、VNDB 查询
    Translation/           # LLM 配置、请求构造与解析、翻译会话（去重、上文、缓存）
    Models/ Library/ Settings/ Support/
  Kazusa/                  # SwiftUI 应用
    Views/                 # 游戏库、详情、设置
    Overlay/               # 翻译悬浮窗（NSPanel）
    Capture/               # ScreenCaptureKit 截图 + Vision OCR
```

数据存放在 `~/Library/Application Support/Kazusa/`，包括 `library.json`、`settings.json`、`Prefixes/`、`Runtimes/`、`Logs/`、`Covers/`。

## 路线图

- [ ] **原生后端**：这些游戏可以完全不用 Wine
  - [x] NScripter 走 ONScripter（打包进 Kazusa.app）
  - [ ] KiriKiri 走 krkrsdl2（需要先确认未修改的商业游戏能不能跑）
  - [ ] System4 走 xsystem4
- [ ] **文本钩子**：自己实现 Textractor 式的 hook，直接从游戏进程里取文本，比 OCR 更准；剪贴板模式现在可以先搭配外部工具使用
- [ ] 视频解码：给前缀装 LAV/quartz 一类的方案，解决 OP/ED 黑屏
- [x] 从 VNDB 拉取封面
- [x] 从 VNDB 拉取简介、品牌等元数据
- [x] 用已配置的 LLM 把 VNDB 英文简介翻成中文
- [x] 全局快捷键（游戏在前台时也能触发识别）、悬浮窗点击穿透
- [ ] 每个游戏独立前缀、存档备份
- [x] 流式翻译输出
- [ ] 翻译结果持久化
- [x] 修复 macOS 27 上 Rosetta 导致 32 位游戏随机崩溃 / 卡死（打补丁的 `wow64cpu.dll`）
- [ ] 为更多 Wine 版本预编译 `wow64cpu.dll`（目前只有 11.21）
- [x] 应用图标、通用二进制（Apple 芯片 + Intel）打包
- [x] 发布第一个 Release（v0.1.0）

## 许可证

Kazusa 以 [GNU 通用公共许可证 v3.0 或更高版本](LICENSE)（GPL-3.0-or-later）发布。

Copyright (C) 2026 Shizuku11451

你可以自由使用、修改和再分发本程序。但分发修改版或基于它的作品时，必须同样以 GPL-3.0 或更高版本公开源代码。

### 第三方组件

Kazusa **不链接**下列组件，只在运行时把它们作为独立程序调用，或使用系统自带的部分。随 Kazusa 分发的第三方文件只有两个，构建脚本和许可证都在各自的目录里：

- 修复版 `wow64cpu.dll`（LGPL-2.1-or-later），见 [ThirdParty/wow64cpu-rosetta](ThirdParty/wow64cpu-rosetta/)；
- ONScripter 程序 `onsyuri`（GPL-2.0-or-later，静态链接了 zlib 许可的 SDL2、FTL 许可的 FreeType、MIT 许可的 HarfBuzz 和 Lua），见 [ThirdParty/onscripter-yuri](ThirdParty/onscripter-yuri/)。

| 组件 | 许可证 | 使用方式 |
|---|---|---|
| [Wine](https://www.winehq.org/) | LGPL-2.1-or-later | 用户自行安装，或从压缩包导入；作为子进程调用 |
| Rosetta 2 | Apple 专有 | macOS 系统组件，由用户通过 `softwareupdate` 安装 |
| SwiftUI / ScreenCaptureKit / Vision / Security | Apple SDK | 系统框架 |
| 冬青黑体等系统字体 | Apple 专有 | 只在 Wine 注册表里引用字体名、把系统字体路径传给 ONScripter，不分发字体文件 |

翻译功能会把识别到的文本发给**用户自己配置**的 LLM 服务，请遵守对应服务的使用条款。

### 贡献

提交代码即表示你同意以 GPL-3.0-or-later 授权你的贡献。请不要提交任何游戏文件、游戏截图或其他受版权保护的素材。

- 遇到游戏打不开、乱码、黑屏，请用「游戏兼容性问题」模板提 issue，附上日志（详情页右上角 ⋯ →“打开日志”）。
- 开发时可以设置 `KAZUSA_HOME=/tmp/kazusa-dev` 使用独立的数据目录，不影响自己的游戏库。
- `swift run kazusa-cli` 可以不开界面直接测试运行时、游戏识别和启动。
