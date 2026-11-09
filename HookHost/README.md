# kazusa-hook

在 Wine 里运行的小程序，把 [LunaHook](../ThirdParty/lunahook/) 接到 Kazusa 上：

1. 加载同目录（或 `--dll-dir`）里的 `LunaHost32/64.dll`；
2. 按进程名（`--name WA2.exe`）或 `--pid` 找到游戏，最多等 `--wait` 秒；
3. 建立管道，用 `CreateRemoteThread` + `LoadLibraryW` 注入 `LunaHook32/64.dll`；
4. 把钩到的文本按行输出 JSON：`ready`、`thread`、`text`、`info`、`detached`、`error` 等，见 `kazusa-hook.c` 开头的注释。

标准输入接受 `hook <特殊码>` 和 `quit`；读到 EOF 也会断开退出，所以调用方要一直开着 stdin。

位数必须和游戏一致：32 位游戏用 `kazusa-hook32.exe`，64 位用 `kazusa-hook64.exe`。

## 构建

```sh
brew install mingw-w64
HookHost/build.sh   # 输出到 HookHost/prebuilt/
```

预编译的 exe 已提交到仓库，改了源码才需要重新构建。

## 手动测试

```sh
(sleep 600) | WINEPREFIX=~/Library/Application\ Support/Kazusa/Prefixes/default-ja \
  wine HookHost/prebuilt/kazusa-hook32.exe --name WA2.exe --codepage 932 \
  --dll-dir 'Z:\path\to\ThirdParty\lunahook\prebuilt\x86'
```
