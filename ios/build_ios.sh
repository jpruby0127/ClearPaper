#!/bin/bash
# 构建未签名 .ipa，供自签（Sideloadly / AltStore / Xcode）安装。
# 整套清晰化引擎已编译进 app：无服务端、不联网、不需要 Python。
#
# 用法：
#   ./build_ios.sh OUT.ipa
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="$1"
ICON_SET="$TOOLS/ios/icons"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
STAGE="$(mktemp -d)/Payload/ScanClean.app"
mkdir -p "$STAGE"

[ -d "$ICON_SET" ] || { echo "缺少图标集：$ICON_SET" >&2; exit 1; }

# -disable-sandbox：让 SwiftUI 的 macro plugin server 在受限构建环境（CI / 沙盒 shell）
# 下也能启动；否则 @State 等宏无法展开。
swiftc -parse-as-library -O -disable-sandbox \
  -target arm64-apple-ios16.0 -sdk "$SDK" \
  -framework SwiftUI -framework UIKit -framework PDFKit -framework ImageIO \
  -o "$STAGE/ScanClean" "$TOOLS/engine/Core.swift" "$TOOLS/ios/App.swift"

cat > "$STAGE/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>ScanClean</string>
  <key>CFBundleIdentifier</key><string>com.local.scanpdf.ios</string>
  <key>CFBundleName</key><string>试卷清晰化</string>
  <key>CFBundleDisplayName</key><string>试卷清晰化</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.2.1</string>
  <key>CFBundleVersion</key><string>4</string>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
  <key>DTPlatformName</key><string>iphoneos</string>
  <key>MinimumOSVersion</key><string>16.0</string>
  <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
  <key>UILaunchScreen</key><dict/>
  <key>UIFileSharingEnabled</key><true/>
  <key>LSSupportsOpeningDocumentsInPlace</key><true/>
  <key>ITSAppUsesNonExemptEncryption</key><false/>
  <key>CFBundleIcons</key>
  <dict>
    <key>CFBundlePrimaryIcon</key>
    <dict>
      <key>CFBundleIconFiles</key>
      <array>
        <string>AppIcon60x60@2x.png</string>
        <string>AppIcon60x60@3x.png</string>
        <string>AppIcon76x76@2x.png</string>
        <string>AppIcon83.5x83.5@2x.png</string>
      </array>
      <key>UIPrerenderedIcon</key><true/>
    </dict>
  </dict>
  <key>CFBundleIconFiles</key>
  <array>
    <string>AppIcon60x60@2x.png</string>
    <string>AppIcon60x60@3x.png</string>
    <string>AppIcon76x76@2x.png</string>
    <string>AppIcon83.5x83.5@2x.png</string>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>PDF 扫描件</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array>
    </dict>
  </array>
  <key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationPortrait</string></array>
</dict>
</plist>
PLIST
echo -n "APPL????" > "$STAGE/PkgInfo"

# 复制仓库中已生成好的图标（无需 Python 环境）。
for f in AppIcon60x60@2x.png AppIcon60x60@3x.png AppIcon76x76@2x.png AppIcon83.5x83.5@2x.png; do
  [ -f "$ICON_SET/$f" ] || { echo "缺少图标 $f" >&2; exit 1; }
  cp "$ICON_SET/$f" "$STAGE/$f"
done

/usr/bin/plutil -lint "$STAGE/Info.plist" >/dev/null
file "$STAGE/ScanClean" | grep -q "arm64" || { echo "编译产物不是 arm64" >&2; exit 1; }

PKG="$(mktemp -d)"
mkdir -p "$PKG/Payload"
cp -R "$STAGE" "$PKG/Payload/ScanClean.app"
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
cd "$PKG"
zip -qrX "$OUT" Payload
echo "已生成未签名 IPA：$OUT ($(du -h "$OUT" | cut -f1))"
echo "全离线：算法已编译进 app，安装后不需要 Mac 或网络"
echo "用 Sideloadly / AltStore 选这个 ipa，填 Apple ID 自签即可安装"
