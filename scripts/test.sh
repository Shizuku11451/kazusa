#!/bin/zsh
# 运行单元测试。只装了 Command Line Tools（没有 Xcode）时，Swift Testing 框架不在默认搜索路径里，需要手动指定。
set -euo pipefail
cd "$(dirname "$0")/.."

DEV="$(xcode-select -p)"
FW="$DEV/Library/Developer/Frameworks"
LIB="$DEV/Library/Developer/usr/lib"
if [[ -d "$FW/Testing.framework" && ! -d "$DEV/Platforms" ]]; then
  exec swift test \
    -Xswiftc -F -Xswiftc "$FW" \
    -Xlinker -F -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$LIB" \
    "$@"
fi
exec swift test "$@"
