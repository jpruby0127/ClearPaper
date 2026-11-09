#!/bin/bash
# 一条命令构建双端产物：
#   dist/ClearPaper-macOS.dmg            （装了 dmgbuild 则是简洁版布局）
#   dist/ClearPaper-iOS-unsigned.ipa
#
# 用法：./scripts/build-all.sh
# 需要：Xcode 命令行工具 + iOS SDK（xcode-select --install）
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$DIST"

echo "==> 1/3 构建 macOS DMG"
if command -v dmgbuild >/dev/null 2>&1 || [ -x "$HOME/.venvs/scanpdf/bin/dmgbuild" ]; then
  "$ROOT/macos/build_dmg.sh" "$DIST/ClearPaper-macOS.dmg"
else
  DEST="$WORK/ClearPaper.app" "$ROOT/macos/build_app.sh"
  mkdir -p "$WORK/dmg/Applications"
  cp -R "$WORK/ClearPaper.app" "$WORK/dmg/"
  ln -s /Applications "$WORK/dmg/Applications"
  hdiutil create -volname "ClearPaper" -srcfolder "$WORK/dmg" -ov -format UDZO \
    "$DIST/ClearPaper-macOS.dmg" >/dev/null
  echo "    $DIST/ClearPaper-macOS.dmg（未装 dmgbuild，使用朴素布局）"
fi

echo "==> 2/3 构建 iOS 未签名 IPA"
"$ROOT/ios/build_ios.sh" "$DIST/ClearPaper-iOS-unsigned.ipa"

echo "==> 3/3 完成"
ls -lh "$DIST"
