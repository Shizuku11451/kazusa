# wow64cpu Rosetta 修复

在较新的 macOS（已确认 macOS 27.0 / 27.2）上，Rosetta 2 处理 32 位与 64 位代码之间的远跳转（`ljmp`）时**偶尔不会切换 CPU 模式**。Wine 的 WoW64 模式每次系统调用都要这样切换，于是 32 位 Windows 程序（绝大多数 galgame 都是 32 位）会随机：

- 在 `wow64cpu.dll+0x1135` 或 `+0x1239` 处页错误（把 RIP 相对偏移当成绝对地址读，例如 `0x2EC5`）；
- 报 `nested exception on signal stack`；
- 或者卡死，`com.apple.rosetta.exceptionserver` 线程占满一个核。

Wine 11.0 到 11.21 都受影响。测试机上《素晴らしき日々》汉化版（BGI 引擎）修复前大约 15 次启动只成功 1 次，换上这个 DLL 后连续 10 次都成功。

## 改了什么

把 `dlls/wow64cpu/cpu.c` 里两个方向的远跳转都换成远返回：

- 32→64 入口：`push $cs64; push $target; lret`，替换原来的 `ljmp *[ptr]`；
- 64→32 返回（`syscall_32to64` 和 `unix_call_32to64`）：压入 `Eip`/`SegCs` 后 `lretq`，替换原来的 `ljmp *(%r14)`。

详见 `wow64cpu-rosetta-farjump.patch`。

## Kazusa 怎么用它

在 Apple Silicon 上启动游戏时，`RosettaWoW64Fix` 会读取运行时版本，然后在下面几个位置找 `wine-<版本>/wow64cpu.dll`：

1. `~/Library/Application Support/Kazusa/Fixes/wow64cpu/`（用户自己编译的版本放这里）；
2. `Kazusa.app/Contents/Resources/wow64cpu-rosetta/prebuilt/`；
3. 开发时用仓库里的 `ThirdParty/wow64cpu-rosetta/prebuilt/`。

找到后，替换 Kazusa 托管的运行时（`Runtimes/` 下）和游戏前缀里的 `wow64cpu.dll`，原文件备份为 `wow64cpu.dll.orig`。**系统里的 Wine（/Applications、Homebrew）不会被改动。**

DLL 和 Wine 版本绑定。要支持别的版本，运行：

```sh
brew install mingw-w64
ThirdParty/wow64cpu-rosetta/build.sh 11.21 ~/Library/Application\ Support/Kazusa/Runtimes/wine-staging-11.21-osx64
```

## 来源与许可

- 补丁来自 [kic99/TEW_IX_on_Mac](https://github.com/kic99/TEW_IX_on_Mac) 的 `wow64cpu-rosetta-fix`（[Philsmith1/wmma6-on-mac](https://github.com/Philsmith1/wmma6-on-mac) 用的也是同一个补丁）。它的思路沿用 Sikarugir 的 Wine 分支里的 `syscall_32to64_rosetta2_workaround`。
- `build.sh` 改编自上面仓库的同名脚本。
- `prebuilt/wine-11.21/wow64cpu.dll` 由 Wine 11.21 的源码打上这个补丁后编译。
- Wine（包括 `dlls/wow64cpu/cpu.c`）以 **GNU LGPL 2.1 或更高版本**发布，见 `COPYING.LIB`。这个目录里的补丁和预编译 DLL 同样遵循 LGPL；按 LGPL 的要求，对应源码就是 Wine 11.21 的源码加上这里的补丁。DLL 作为独立文件随 Kazusa 分发，Kazusa 其余部分仍是 GPL-3.0-or-later。
