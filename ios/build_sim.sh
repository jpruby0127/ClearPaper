#!/bin/bash
# 在 iOS 模拟器里构建并运行 on-device SwiftUI app，可顺手截一张图。
# 用法：./build_sim.sh [screenshot.png]
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS="$(cd "$SCRIPT_DIR/.." && pwd)"
SHOT="${1:-}"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
STAGE="$(mktemp -d)/ScanClean.app"
mkdir -p "$STAGE"

if ! xcrun simctl list runtimes | grep -q "iOS"; then
  echo "本机尚未安装 iOS Simulator 运行时。用 Xcode > Settings > Components 下载，或执行：" >&2
  echo "  xcodebuild -downloadPlatform iOS" >&2
  exit 2
fi

UUID_RE='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
BOOTED="$(xcrun simctl list devices booted | grep -m1 -oE "$UUID_RE" || true)"
if [ -z "$BOOTED" ]; then
  DEV="$(xcrun simctl list devices available | grep -m1 -oE "$UUID_RE" || true)"
  if [ -z "$DEV" ]; then
    RT="$(xcrun simctl list runtimes | grep -m1 -oE 'com.apple.CoreSimulator.SimRuntime.iOS-[0-9-]+' || true)"
    [ -n "$RT" ] || { echo "没有 iOS 运行时，请先在 Xcode > Components 下载" >&2; exit 2; }
    TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-16"
    DEV="$(xcrun simctl create "ScanClean 测试" "$TYPE" "$RT" 2>/dev/null || true)"
    if ! echo "$DEV" | grep -qE "^[0-9A-Fa-f-]{36}$"; then
      # 部分运行时只提供受限设备集；回退到它声明的第一个设备类型。
      TYPE="$(xcrun simctl list runtimes -j | /usr/bin/python3 -c \
        'import json,sys; d=json.load(sys.stdin); t=d["runtimes"][0].get("supportedDeviceTypes") or []; print(t[0]["identifier"] if t else "")')"
      [ -n "$TYPE" ] || { echo "运行时未提供兼容设备类型" >&2; exit 2; }
      DEV="$(xcrun simctl create "ScanClean 测试" "$TYPE" "$RT")"
    fi
    echo "已创建模拟器设备：$DEV ($TYPE)"
  fi
  xcrun simctl boot "$DEV" >/dev/null 2>&1 || true
  BOOTED="$DEV"
fi

swiftc -parse-as-library -O -disable-sandbox \
  -target arm64-apple-ios16.0-simulator -sdk "$SDK" \
  -framework SwiftUI -framework UIKit -framework PDFKit -framework ImageIO \
  -o "$STAGE/ScanClean" "$TOOLS/engine/Core.swift" "$TOOLS/ios/App.swift"

cp "$TOOLS/ios/sim_info.plist" "$STAGE/Info.plist"
echo -n "APPL????" > "$STAGE/PkgInfo"
/usr/bin/plutil -lint "$STAGE/Info.plist" >/dev/null

xcrun simctl install "$BOOTED" "$STAGE"
xcrun simctl launch "$BOOTED" com.local.scanpdf.ios >/dev/null
echo "已安装并启动模拟器：$BOOTED  (com.local.scanpdf.ios)"
if [ -n "$SHOT" ]; then
  sleep 2
  xcrun simctl io "$BOOTED" screenshot "$SHOT"
  echo "界面截图：$SHOT"
fi
echo "提示：把 PDF 拖进模拟器窗口即可走一遍 导入→处理→打印/分享 全链路"
