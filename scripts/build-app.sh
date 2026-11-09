#!/bin/bash
# 打包成 Kazusa.app（release 构建 + ad-hoc 签名）。用法：scripts/build-app.sh [输出目录]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-build}"
APP="$OUT/Kazusa.app"
VERSION="0.1.0"

# 通用二进制（Apple 芯片 + Intel）。只装了 Command Line Tools 时 `--arch a --arch b` 需要 Xcode，
# 所以分别构建两个架构再用 lipo 合并。
swift build -c release --product Kazusa --triple arm64-apple-macosx14.0
swift build -c release --product Kazusa --triple x86_64-apple-macosx14.0
BIN="$(mktemp -d)/Kazusa"
lipo -create .build/arm64-apple-macosx/release/Kazusa .build/x86_64-apple-macosx/release/Kazusa -output "$BIN"

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
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSScreenCaptureUsageDescription</key><string>Kazusa 需要截取游戏画面中的文字进行 OCR 翻译。</string>
</dict>
</plist>
PLIST

# ad-hoc 签名：屏幕录制权限是按签名记的，不签名每次重新构建都得重新授权。
codesign --force --sign - --timestamp=none "$APP"
echo "✅ $APP"
