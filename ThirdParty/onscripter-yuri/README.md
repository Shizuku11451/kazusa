# ONScripter（OnscripterYuri）

NScripter 引擎的开源重实现，Kazusa 用它**不经过 Wine** 直接运行 NScripter 游戏（`0.txt` / `00.txt` / `nscript.dat` + `.nsa` 封包）。

- 上游：[YuriSizuku/OnscripterYuri](https://github.com/YuriSizuku/OnscripterYuri) `v0.7.7beta`（提交 `08f744b`），基于 ONScripter 和 ONScripter-Jh
- 许可证：GPL-2.0-or-later（见 [COPYING](COPYING)）。Kazusa 只把它当作独立程序启动，不链接它

## 构建

```sh
brew install cmake
ThirdParty/onscripter-yuri/build.sh
```

脚本会下载固定版本的源码，把 SDL2、SDL2_image、SDL2_mixer、SDL2_ttf（自带 FreeType、HarfBuzz）和 Lua 编成 arm64 + x86_64 静态库，再链接出 `prebuilt/onsyuri`。产物只依赖 macOS 系统框架，最低支持 macOS 11：

- 图片用系统的 ImageIO 解码；
- 音频用 SDL_mixer 内置的 WAV / OGG（stb_vorbis）/ MP3（minimp3）/ FLAC（dr_flac）解码，MIDI 用系统的 AudioToolbox；
- 去掉了上游 macOS 配置里的 `USE_GLES`（只用于 `--sharpness`）和 `USE_FILELOG`（会往游戏目录写 `stdout.txt` / `stderr.txt`）。

静态链接进去的库的许可证在 [licenses/](licenses/)：SDL2 系列为 zlib，FreeType 为 FTL，HarfBuzz 和 Lua 为 MIT。

`prebuilt/onsyuri` 提交在仓库里，`scripts/build-app.sh` 会把它和这些许可证一起放进 `Kazusa.app/Contents/Resources/onscripter-yuri/`。

## Kazusa 怎么用它

引擎识别为 NScripter 的游戏，“运行方式”默认是**自动**，也就是用 ONScripter；在详情页可以改回 Wine（例如改过引擎的汉化版跑不起来时）。启动参数：

```
onsyuri --root <游戏目录> --enc:<sjis|gbk|utf8> [--font <字体>] [游戏的启动参数...]
```

- **编码**：读取 `0.txt` / `00.txt` / `nscript.dat`（异或 0x84 解密）的开头，是合法 UTF-8 就用 `utf8`，否则日文区域用 `sjis`、中文区域用 `gbk`。onsyuri 不支持 Big5，繁体中文版只能按 GBK 读；
- **字体**：游戏目录里有 `default.ttf` 就用它，否则按区域用系统自带的ヒラギノ角ゴシック（日文）或冬青黑体（中文）；
- **存档**：留在游戏目录（ONScripter 的默认位置），和 Windows 版通用。

更多参数（`--fullscreen`、`--scale`、`--save-dir` 等）运行 `prebuilt/onsyuri --help` 查看，填在详情页的“启动参数”里即可。
