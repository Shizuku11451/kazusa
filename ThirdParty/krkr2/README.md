# krkr2

吉里吉里 2 / 吉里吉里 Z（KiriKiri）引擎的开源重实现，是 Kirikiroid2 的延续。Kazusa 用它**不经过 Wine** 直接运行 KiriKiri 游戏（`data.xp3` 等 `.xp3` 封包，或散装的 `startup.tjs`）。

- 上游：[2468785842/krkr2](https://github.com/2468785842/krkr2)，提交 `c8d0e38`
- 许可证：上游代码按 MIT 发布，包含的吉里吉里 / 吉里吉里 Z 源码是 BSD 式的吉里吉里许可证（见 [COPYING](COPYING)）。Kazusa 只把它当作独立程序启动，不链接它
- 静态链接进去的 vcpkg 依赖（cocos2d-x、FFmpeg（LGPL，未开 GPL 组件）、Boost、OpenCV、FreeType、libarchive、unrar 等）的许可证在 [licenses/](licenses/)
- 只有 arm64：上游的 macOS 构建只支持 Apple 芯片，Intel Mac 上 Kazusa 对 KiriKiri 游戏用 Wine

## Kazusa 的补丁

[kazusa.patch](kazusa.patch) 改了这些（都只影响用 `--game` 直接启动游戏的情况）：

- **桌面窗口**：不显示为触屏设计的游戏内菜单；窗口按游戏的分辨率和宽高比调整大小并居中（小于 1280 宽的游戏会放大，最大占屏幕的 85%），窗口标题跟着游戏标题走；
- **出错时返回非 0**：脚本异常等启动错误原来会以 0 退出，现在返回 1，Kazusa 据此自动改用 Wine；
- **建多级目录**：修正 macOS 上 `TVPCreateFolders` 把成功当失败的问题（存档目录在多级子目录里时建不出来）；
- **文本输出**：设了环境变量 `KAZUSA_TEXT_PIPE` 时，`Layer.drawText` 画的字按图层和字号分开收集（字号不同的注音不会混进句子），停顿 0.4 秒后按 Kazusa 文本钩子的 JSON 行格式写进这个命名管道，Kazusa 自动挑字数最多的那一路当对白（见 `cpp/core/visual/kazusa_text.cpp`）；
- **不依赖 Homebrew**：FFmpeg 关掉 xlib / xcb / SDL2，否则会链接到本机 Homebrew 里的 libxcb，换台 Mac 就打不开。

## 构建

```sh
brew install cmake ninja bison autoconf autoconf-archive automake libtool pkg-config
ThirdParty/krkr2/build.sh
```

需要完整的 Xcode。脚本会下载固定提交的源码、打补丁，用 vcpkg 把一百多个依赖编成静态库（第一次要一个多小时），再链接出 `prebuilt/krkr2.app`（strip 后约 55 MB，其中 19 MB 是它自带的思源黑体，引擎找不到游戏指定的字体时用它）。

`prebuilt/krkr2.app` 提交在仓库里，`scripts/build-app.sh` 会把它和许可证一起放进 `Kazusa.app/Contents/Resources/krkr2/`。

## Kazusa 怎么用它

引擎识别为 KiriKiri 的游戏，“运行方式”默认是**自动**：

1. 游戏目录里有 `startup.tjs`，或者 `data.xp3` 里的 `startup.tjs` 能读出文本（没加密），就用 krkr2；
2. 封包加了密（大部分商业游戏用 exe 里的解密代码，krkr2 没有）或者数据嵌在 exe 里，就用 Wine；
3. 用 krkr2 启动后一分钟内出错退出（插件不支持、脚本用了没实现的功能等），自动改用 Wine 重新启动，并记住这个游戏以后用 Wine。

启动参数：

```
krkr2 --game <游戏目录> [游戏的启动参数...]
```

存档在游戏目录的 `savedata/`，和 Windows 版的位置一样。
