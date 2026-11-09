#!/bin/bash
# 一条命令构建双端产物（与 .github/workflows/build.yml 步骤一致）：
#   dist/ScanClean-macOS.dmg
#   dist/ScanClean-iOS-unsigned.ipa
#
# 用法：./scripts/build-all.sh
# 需要：Xcode 命令行工具 + iOS SDK（xcode-select --install）
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$DIST"

echo "==> 1/3 构建 macOS App"
DEST="$WORK/试卷清晰化.app" "$ROOT/macos/build_app.sh"

echo "==> 2/3 打包 DMG"
mkdir -p "$WORK/dmg/Applications"
cp -R "$WORK/试卷清晰化.app" "$WORK/dmg/"
ln -s /Applications "$WORK/dmg/Applications"
hdiutil create -volname "试卷清晰化" -srcfolder "$WORK/dmg" -ov -format UDZO \
  "$DIST/ScanClean-macOS.dmg" >/dev/null
echo "    $DIST/ScanClean-macOS.dmg"

echo "==> 3/3 构建 iOS 未签名 IPA"
"$ROOT/ios/build_ios.sh" "$DIST/ScanClean-iOS-unsigned.ipa"
echo "    $DIST/ScanClean-iOS-unsigned.ipa"

echo
echo "完成："
ls -lh "$DIST"
