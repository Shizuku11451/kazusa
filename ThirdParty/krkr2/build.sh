#!/bin/bash
# 从源码构建 krkr2（吉里吉里 2 / KiriKiri Z 的开源重实现），打上 Kazusa 的补丁，产出 prebuilt/krkr2.app。
#
# 依赖由上游的 vcpkg 清单拉取并编成 arm64 静态库（cocos2d-x、FFmpeg、Boost 等一百多个包，
# 第一次要编一个多小时，之后有 vcpkg 二进制缓存会快很多）。产物只依赖 macOS 系统框架。
# 只出 arm64：上游的 vcpkg 三元组只有 arm64-osx，Intel Mac 上 Kazusa 会改用 Wine。
#
# 需要：Xcode（不只是 Command Line Tools，cocos2d-x 要用完整 SDK）、cmake、ninja、
#      新版 bison（brew install cmake ninja bison autoconf autoconf-archive automake libtool pkg-config）、git。
# 用法：ThirdParty/krkr2/build.sh [工作目录]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-${TMPDIR:-/tmp}/kazusa-krkr2-build}"
OUT="$HERE/prebuilt"

KRKR2_COMMIT="c8d0e384ed52366b4584244f0a8c011308da5516" # 2468785842/krkr2 main

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PATH="$(brew --prefix bison)/bin:$PATH"

mkdir -p "$WORK"
cd "$WORK"
if [[ ! -d krkr2 ]]; then
  git clone -q https://github.com/2468785842/krkr2.git krkr2
fi
git -C krkr2 checkout -q --force "$KRKR2_COMMIT"
[[ "$(git -C krkr2 rev-parse HEAD)" == "$KRKR2_COMMIT" ]] || { echo "krkr2 提交不对" >&2; exit 1; }
git -C krkr2 apply "$HERE/kazusa.patch"

if [[ -z "${VCPKG_ROOT:-}" ]]; then
  export VCPKG_ROOT="$WORK/vcpkg"
  [[ -d "$VCPKG_ROOT" ]] || git clone -q https://github.com/microsoft/vcpkg.git "$VCPKG_ROOT"
  [[ -x "$VCPKG_ROOT/vcpkg" ]] || "$VCPKG_ROOT/bootstrap-vcpkg.sh" -disableMetrics
fi

cd krkr2
cmake --preset="MacOS Release Config" -DENABLE_TESTS=OFF -DBUILD_TOOLS=OFF
cmake --build --preset="MacOS Release Build" --target krkr2

APP="out/macos/release/bin/krkr2/krkr2.app"
rm -rf "$OUT/krkr2.app"
mkdir -p "$OUT"
cp -R "$APP" "$OUT/"
strip -x "$OUT/krkr2.app/Contents/MacOS/krkr2"
# strip 会让链接时的签名失效，Apple 芯片上不签名的程序不能运行。先 ad-hoc 签上，
# 打包时 scripts/build-app.sh 再用 Kazusa 的证书重签。
codesign --force --sign - "$OUT/krkr2.app"
cp LICENSE "$HERE/COPYING"
# 静态链接进去的 vcpkg 依赖的许可证，随二进制一起分发（Boost 各子库都是 BSL-1.0，只留一份）。
LIC="$HERE/licenses"
rm -rf "$LIC" && mkdir -p "$LIC"
for f in out/macos/release/vcpkg_installed/arm64-osx/share/*/copyright; do
  pkg="$(basename "$(dirname "$f")")"
  # 只用于构建 / 测试的工具不进二进制。
  case "$pkg" in boost-*|boost_*|vcpkg-*|catch2|pkgconf) continue ;; esac
  cp "$f" "$LIC/$pkg.txt"
done
cp out/macos/release/vcpkg_installed/arm64-osx/share/boost-core/copyright "$LIC/boost.txt"
lipo -info "$OUT/krkr2.app/Contents/MacOS/krkr2"
echo "✅ $OUT/krkr2.app"
