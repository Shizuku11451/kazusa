#!/bin/bash
# 交叉编译 kazusa-hook32.exe / kazusa-hook64.exe（需要 mingw-w64：brew install mingw-w64）。
# 产物放在 HookHost/prebuilt/，和源码一起提交，这样构建 Kazusa.app 时不需要 mingw。
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p prebuilt
FLAGS=(-std=c11 -O2 -Wall -Wextra -municode -static -s)
i686-w64-mingw32-gcc "${FLAGS[@]}" -o prebuilt/kazusa-hook32.exe kazusa-hook.c
x86_64-w64-mingw32-gcc "${FLAGS[@]}" -o prebuilt/kazusa-hook64.exe kazusa-hook.c
ls -la prebuilt
