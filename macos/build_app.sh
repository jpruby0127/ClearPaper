#!/bin/bash
# 构建 ClearPaper 的 macOS 原生版 .app
# 清理引擎（engine/Core.swift 的 ScanCore）直接编译进包，零依赖、全离线。
#
# 用法：
#   ./build_app.sh                          # 默认：非沙盒 + 强化运行时，可直接发给朋友（需 Developer ID 公证）
#   SANDBOX=1 ./build_app.sh                # 上架版：开启 App Sandbox，符合 Mac App Store 要求
#   SIGN_ID="身份名称" ./build_app.sh       # 指定签名证书（默认自动挑可用的 Apple 证书，没有则 ad-hoc）
#   DEST=/path/to/App.app ./build_app.sh    # 指定输出 .app 路径（默认 ~/Applications/ClearPaper.app）
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS="$(cd "$SCRIPT_DIR/.." && pwd)"
APP="${DEST:-$HOME/Applications/ClearPaper.app}"
NAME="ClearPaper"
BID="com.jpruby.clearpaper"
ICON="$TOOLS/macos/Icon.icns"
SANDBOX="${SANDBOX:-0}"

[ -f "$ICON" ] || { echo "缺少图标母版：$ICON" >&2; exit 1; }
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 挑一个可用的签名身份；都没有就 ad-hoc。
if [ -n "${SIGN_ID:-}" ]; then
  IDENTITY="$SIGN_ID"
else
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -oE '[0-9A-F]{40} "([^"]+)"' | head -1 | sed -E 's/.* "(.*)"/\1/')"
  [ -n "$IDENTITY" ] || IDENTITY="-"
fi
echo "签名身份：${IDENTITY:-（ad-hoc）}"

ENT=""
if [ "${SANDBOX:-0}" = "1" ]; then
  ENT="$TOOLS/macos/entitlements-appstore.plist"
  [ -f "$ENT" ] || { echo "缺少 $ENT" >&2; exit 1; }
  echo "构建模式：App Store 沙盒版"
else
  echo "构建模式：直接分发版（非沙盒，含强化运行时）"
fi

if ! swiftc -O -disable-sandbox -target "$(uname -m)-apple-macosx12.0" \
  -framework AppKit -framework Foundation -framework PDFKit \
  -framework ImageIO -framework CoreGraphics \
  -o "$APP/Contents/MacOS/$NAME.new" \
  "$TOOLS/engine/Core.swift" "$TOOLS/engine/Merge.swift" "$TOOLS/macos/main.swift"; then
  echo "编译失败，未写入目标" >&2
  rm -f "$APP/Contents/MacOS/$NAME.new"
  exit 1
fi
mv "$APP/Contents/MacOS/$NAME.new" "$APP/Contents/MacOS/$NAME"
cp "$ICON" "$APP/Contents/Resources/Icon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BID</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>ClearPaper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.5.0</string>
  <key>CFBundleVersion</key><string>10</string>
  <key>CFBundleIconFile</key><string>Icon.icns</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 jpruby · 全离线处理</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>PDF 扫描件</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.pdf</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST
/usr/bin/plutil -lint "$APP/Contents/Info.plist" >/dev/null

# 签名：强化运行时（除 ad-hoc 外都加），需要时带沙盒授权。
if [ "$IDENTITY" = "-" ]; then
  codesign --force --deep -s - "$APP" >/dev/null 2>&1 || codesign --force -s - "$APP"
elif [ -n "$ENT" ]; then
  codesign --force --deep --options runtime -s "$IDENTITY" --entitlements "$ENT" "$APP"
else
  codesign --force --deep --options runtime -s "$IDENTITY" "$APP"
fi
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$APP" 2>/dev/null || true

echo "已安装：$APP （1.5.0，自包含 Swift 引擎，sandbox=${SANDBOX:-0}）"
echo "在 Launchpad 或 访达 › 应用程序 里搜「ClearPaper」即可打开"
