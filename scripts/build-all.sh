#!/bin/bash
# 一条命令构建双端产物：
#   dist/ScanClean-macOS.dmg            （装了 dmgbuild 则是简洁版布局）
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

echo "==> 1/3 构建 macOS DMG"
if command -v dmgbuild >/dev/null 2>&1 || [ -x "$HOME/.venvs/scanpdf/bin/dmgbuild" ]; then
  "$ROOT/macos/build_dmg.sh" "$DIST/ScanClean-macOS.dmg"
else
  DEST="$WORK/试卷清晰化.app" "$ROOT/macos/build_app.sh"
  mkdir -p "$WORK/dmg/Applications"
  cp -R "$WORK/试卷清晰化.app" "$WORK/dmg/"
  ln -s /Applications "$WORK/dmg/Applications"
  hdiutil create -volname "试卷清晰化" -srcfolder "$WORK/dmg" -ov -format UDZO \
    "$DIST/ScanClean-macOS.dmg" >/dev/null
  echo "    $DIST/ScanClean-macOS.dmg（未装 dmgbuild，使用朴素布局）"
fi

echo "==> 2/3 构建 iOS 未签名 IPA"
"$ROOT/ios/build_ios.sh" "$DIST/ScanClean-iOS-unsigned.ipa"

echo "==> 3/3 完成"
ls -lh "$DIST"
