# LunaHook（文本钩子）

Kazusa 用 [LunaHook](https://github.com/HIllya51/LunaTranslator/tree/main/src/NativeImpl/LunaHook) 直接从游戏进程里读取文本，代替 OCR。LunaHook 是 LunaTranslator 的一部分，由 Textractor 发展而来，内置几百种 galgame 引擎的钩子规则，大多数游戏不需要手动找特殊码。

- 许可证：GPL-3.0（见 [COPYING](COPYING)）；它用到的第三方组件的许可证在 [licenses/](licenses/)。
- 版本：LunaTranslator **v12.1.3.9** 发布包里的文件，没有修改。源码：<https://github.com/HIllya51/LunaTranslator/tree/v12.1.3.9/src/NativeImpl/LunaHook>

| 文件 | 来自 | SHA-256 |
|---|---|---|
| `prebuilt/x86/LunaHost32.dll` | `LunaTranslator_x86_winxp.zip` → `files/LunaHook/` | `19412fd39ee301a0ae7620f7e691e0f77a38f5e3093fa2da834a75869358a946` |
| `prebuilt/x86/LunaHook32.dll` | 同上 | `5676a47f580c0ff0aff30ce7ffbe353bc48bba38e9a866383649cc14ef8ddc21` |
| `prebuilt/x64/LunaHost64.dll` | `LunaTranslator_x64.zip` → `files/LunaHook/` | `94a0c47c62d7492587f18eef8e9ebf1d0f7656775eecc0b49c2825d1d63f87b7` |
| `prebuilt/x64/LunaHook64.dll` | 同上 | `e1bee73d40d3a360e390b7bbbd6e36c768ff33b7fa0eec46b63707bb1565c1f9` |

32 位用 winxp 包里的版本：它用 VC-LTL 编译，只依赖系统自带的 `msvcrt.dll`，在 Wine 里最省事。Host 和 Hook 必须来自同一个包（两边会校验版本）。

## 怎么用

Kazusa 自己的小程序 [`kazusa-hook32/64.exe`](../../HookHost/)（源码在 `HookHost/`）和游戏跑在同一个 Wine 前缀里：

1. 加载 `LunaHost32.dll`（或 64 位版），注册回调；
2. 按进程名找到游戏，建立管道，用 `CreateRemoteThread` + `LoadLibraryW` 把 `LunaHook32.dll` 注入游戏（位数和游戏一致，不需要跨位数注入）；
3. LunaHook 在游戏里识别引擎、自动下钩子，钩到的文本经管道传回，`kazusa-hook` 再按行输出 JSON 给 Kazusa。

## 更新

从 LunaTranslator 的 Release 下载 `LunaTranslator_x86_winxp.zip` 和 `LunaTranslator_x64.zip`，按上表替换文件，更新这里的版本号和校验和，然后实际挂一个游戏试试。
