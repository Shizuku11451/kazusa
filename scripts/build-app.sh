#!/bin/bash
# 打包成 Kazusa.app（release 构建 + ad-hoc 签名）。用法：scripts/build-app.sh [输出目录]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-build}"
APP="$OUT/Kazusa.app"
VERSION="0.1.0"

swift build -c release --product Kazusa
BIN="$(swift build -c release --show-bin-path)/Kazusa"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Kazusa"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Kazusa</string>
    <key>CFBundleDisplayName</key><string>Kazusa</string>
    <key>CFBundleIdentifier</key><string>app.kazusa.Kazusa</string>
    <key>CFBundleExecutable</key><string>Kazusa</string>
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
