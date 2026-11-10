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
# zip 前会 cd 到临时目录，先把输出路径转成绝对路径，否则相对路径会失效。
case "$OUT" in
  /*) ;;
  *) OUT="$PWD/$OUT" ;;
esac
ICON_SET="$TOOLS/ios/icons"
LOGO="$TOOLS/ios/Logo.png"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
STAGE="$(mktemp -d)/Payload/ClearPaper.app"
mkdir -p "$STAGE"

[ -d "$ICON_SET" ] || { echo "缺少图标集：$ICON_SET" >&2; exit 1; }
[ -f "$LOGO" ] || { echo "缺少 Logo：$LOGO" >&2; exit 1; }

# -disable-sandbox：让 SwiftUI 的 macro plugin server 在受限构建环境（CI / 沙盒 shell）
# 下也能启动；否则 @State 等宏无法展开。
swiftc -parse-as-library -O -disable-sandbox \
  -target arm64-apple-ios16.0 -sdk "$SDK" \
  -framework SwiftUI -framework UIKit -framework PDFKit -framework ImageIO \
  -framework Vision -framework VisionKit -framework PhotosUI \
  -o "$STAGE/ClearPaper" "$TOOLS/engine/Core.swift" "$TOOLS/engine/Merge.swift" \
     "$TOOLS/ios/Capture.swift" "$TOOLS/ios/App.swift"

cat > "$STAGE/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>ClearPaper</string>
  <key>CFBundleIdentifier</key><string>com.jpruby.clearpaper.ios</string>
  <key>CFBundleName</key><string>ClearPaper</string>
  <key>CFBundleDisplayName</key><string>ClearPaper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.5.0</string>
  <key>CFBundleVersion</key><string>7</string>
  <key>CFBundleGetInfoString</key><string>ClearPaper 1.5.0 (7) by jpruby · 全离线处理</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 jpruby. MIT License.</string>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
  <key>DTPlatformName</key><string>iphoneos</string>
  <key>MinimumOSVersion</key><string>16.0</string>
  <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
  <key>UILaunchScreen</key><dict/>
  <key>UIFileSharingEnabled</key><true/>
  <key>LSSupportsOpeningDocumentsInPlace</key><true/>
  <key>ITSAppUsesNonExemptEncryption</key><false/>
  <key>NSCameraUsageDescription</key><string>用文档相机拍摄试卷，自动找边并矫正透视；照片只在本机处理，不会上传。</string>
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
cp "$LOGO" "$STAGE/Logo.png"

/usr/bin/plutil -lint "$STAGE/Info.plist" >/dev/null
file "$STAGE/ClearPaper" | grep -q "arm64" || { echo "编译产物不是 arm64" >&2; exit 1; }

PKG="$(mktemp -d)"
mkdir -p "$PKG/Payload"
cp -R "$STAGE" "$PKG/Payload/ClearPaper.app"
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
cd "$PKG"
zip -qrX "$OUT" Payload
echo "已生成未签名 IPA：$OUT ($(du -h "$OUT" | cut -f1))"
echo "全离线：算法已编译进 app，安装后不需要 Mac 或网络"
echo "用 Sideloadly / AltStore 选这个 ipa，填 Apple ID 自签即可安装"
