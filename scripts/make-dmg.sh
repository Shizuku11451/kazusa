#!/bin/zsh
# 把 build/Kazusa.app 做成 dmg 安装包：打开后把 Kazusa 拖进旁边的「应用程序」就装好了。
# 用法：scripts/make-dmg.sh [Kazusa.app 路径]，默认 build/Kazusa.app（先运行 scripts/build-app.sh）。
# 输出 build/Kazusa-<版本>-macOS.dmg 和对应的 .sha256。
set -euo pipefail
ARG="${1:+${1:A}}"  # cd 之前先转成绝对路径
cd "$(dirname "$0")/.."

APP="${ARG:-build/Kazusa.app}"
[[ -d "$APP" ]] || { echo "找不到 $APP，先运行 scripts/build-app.sh" >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/Kazusa-${VERSION}-macOS.dmg"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Kazusa.app"
ln -s /Applications "$STAGE/应用程序"

rm -f "$DMG" "$DMG.sha256"
# ULFO（lzfse 压缩）需要 macOS 10.11+，比 UDZO 小；Kazusa 本身要求 macOS 14。
hdiutil create -volname "Kazusa $VERSION" -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
(cd build && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "✅ $DMG"
cat "$DMG.sha256"
