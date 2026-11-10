#!/bin/bash
# 打包成 Kazusa.app（release 构建 + ad-hoc 签名）。用法：scripts/build-app.sh [输出目录]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-build}"
APP="$OUT/Kazusa.app"
VERSION="0.2.0"

# 通用二进制（Apple 芯片 + Intel）。只装了 Command Line Tools 时 `--arch a --arch b` 需要 Xcode，
# 所以分别构建两个架构再用 lipo 合并。
# 新版 SwiftPM 两个架构输出到同一个目录，所以每构建完一个就立刻拷走。
TMP="$(mktemp -d)"
for ARCH in arm64 x86_64; do
  swift build -c release --product Kazusa --triple $ARCH-apple-macosx14.0
  cp "$(swift build -c release --triple $ARCH-apple-macosx14.0 --show-bin-path)/Kazusa" "$TMP/Kazusa-$ARCH"
  [ "$(lipo -archs "$TMP/Kazusa-$ARCH")" = "$ARCH" ] || { echo "构建产物不是 $ARCH"; exit 1; }
  # 新版 SwiftPM 把二进制里记的 SDK 版本写成了最低系统版本（14.0），macOS 就当它是老程序，
  # 不给液态玻璃。改回真实的 SDK 版本。
  vtool -set-build-version macos 14.0 "$(xcrun --show-sdk-version)" -replace -output "$TMP/Kazusa-$ARCH" "$TMP/Kazusa-$ARCH"
done
BIN="$TMP/Kazusa"
lipo -create "$TMP/Kazusa-arm64" "$TMP/Kazusa-x86_64" -output "$BIN"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Kazusa"
# 应用图标：由 scripts/make-icon.swift 用代码画出，再生成各尺寸的 .icns。
ICONWORK="$(mktemp -d)"
swift scripts/make-icon.swift "$ICONWORK/icon.png" >/dev/null
ICONSET="$ICONWORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONWORK/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$ICONWORK/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -r "$ICONWORK"

# Rosetta 修复用的 wow64cpu.dll（LGPL，附带补丁和许可证），见 ThirdParty/wow64cpu-rosetta。
mkdir -p "$APP/Contents/Resources/wow64cpu-rosetta"
cp -R ThirdParty/wow64cpu-rosetta/prebuilt ThirdParty/wow64cpu-rosetta/COPYING.LIB \
      ThirdParty/wow64cpu-rosetta/wow64cpu-rosetta-farjump.patch ThirdParty/wow64cpu-rosetta/README.md \
      "$APP/Contents/Resources/wow64cpu-rosetta/"

# 原生运行 NScripter 游戏的 ONScripter（GPL-2.0-or-later，独立程序），见 ThirdParty/onscripter-yuri。
ONS="$APP/Contents/Resources/onscripter-yuri"
mkdir -p "$ONS"
cp ThirdParty/onscripter-yuri/prebuilt/onsyuri ThirdParty/onscripter-yuri/COPYING ThirdParty/onscripter-yuri/README.md "$ONS/"
cp -R ThirdParty/onscripter-yuri/licenses "$ONS/"

# 原生运行 KiriKiri 游戏的 krkr2（MIT / 吉里吉里许可证，独立程序，只有 arm64），见 ThirdParty/krkr2。
KR="$APP/Contents/Resources/krkr2"
mkdir -p "$KR"
cp -R ThirdParty/krkr2/prebuilt/krkr2.app "$KR/"
cp ThirdParty/krkr2/COPYING ThirdParty/krkr2/README.md ThirdParty/krkr2/kazusa.patch "$KR/"
cp -R ThirdParty/krkr2/licenses "$KR/"

# 文本钩子：kazusa-hook32/64.exe（本项目，GPL-3.0）+ LunaHook（GPL-3.0），都是在 Wine 里运行的 Windows 程序。
# 见 HookHost/ 和 ThirdParty/lunahook。
HOOK="$APP/Contents/Resources/texthook"
mkdir -p "$HOOK"
cp HookHost/prebuilt/kazusa-hook32.exe HookHost/prebuilt/kazusa-hook64.exe "$HOOK/"
cp -R ThirdParty/lunahook/prebuilt/x86 ThirdParty/lunahook/prebuilt/x64 "$HOOK/"
cp ThirdParty/lunahook/COPYING ThirdParty/lunahook/README.md "$HOOK/"
cp -R ThirdParty/lunahook/licenses "$HOOK/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Kazusa</string>
    <key>CFBundleDisplayName</key><string>Kazusa</string>
    <key>CFBundleIdentifier</key><string>app.kazusa.Kazusa</string>
    <key>CFBundleExecutable</key><string>Kazusa</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSScreenCaptureUsageDescription</key><string>Kazusa 需要截取游戏画面中的文字进行 OCR 翻译。</string>
</dict>
</plist>
PLIST

# 签名。屏幕录制等权限是按签名记的：
# - ad-hoc 签名只认这一次构建的 cdhash，每次重新构建都得重新授权；
# - 用固定的证书签名，系统认“bundle ID + 证书”，重新构建后权限仍然有效。
# 默认找钥匙串里名为 “Kazusa Local Signing” 的证书（本机自签名即可，见 README），
# 也可以用 KAZUSA_SIGN_IDENTITY 指定；都没有就退回 ad-hoc（CI 就是这样）。
IDENTITY="${KAZUSA_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]] && security find-certificate -c "Kazusa Local Signing" >/dev/null 2>&1; then
    IDENTITY="Kazusa Local Signing"
fi
IDENTITY="${IDENTITY:--}"
# 内嵌的可执行文件要先单独签名，再签整个 .app。
codesign --force --sign "$IDENTITY" --timestamp=none "$ONS/onsyuri"
codesign --force --sign "$IDENTITY" --timestamp=none "$KR/krkr2.app"
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
echo "✅ ${APP}（签名：$([[ "$IDENTITY" == - ]] && echo ad-hoc || echo "$IDENTITY")）"
