#!/bin/bash
# 生成「简洁版」DMG：打开后就是 App + Applications 两个大图标，拖过去即可安装。
# 需要 dmgbuild（pip install dmgbuild）与 macOS 的 hdiutil。
#
# 用法：
#   ./macos/build_dmg.sh                 # 输出 dist/ClearPaper-macOS-1.4.0.dmg
#   ./macos/build_dmg.sh out.dmg         # 指定输出
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="${1:-$ROOT/dist/ClearPaper-macOS-1.4.0.dmg}"
VOLNAME="ClearPaper"
APPNAME="ClearPaper"

# 找 dmgbuild：PATH 优先，其次常见的 venv 位置
DMGBUILD="${DMGBUILD:-}"
if [ -z "$DMGBUILD" ]; then
  if command -v dmgbuild >/dev/null 2>&1; then
    DMGBUILD="$(command -v dmgbuild)"
  elif [ -x "$HOME/.venvs/scanpdf/bin/dmgbuild" ]; then
    DMGBUILD="$HOME/.venvs/scanpdf/bin/dmgbuild"
  else
    echo "缺少 dmgbuild。安装：python3 -m pip install dmgbuild" >&2
    exit 2
  fi
fi
DMGPY="$(dirname "$DMGBUILD")/python"
[ -x "$DMGPY" ] || DMGPY="python3"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"
APP="$STAGE/$APPNAME.app"
mkdir -p "$STAGE" "$(dirname "$OUT")"

echo "==> 构建 App"
DEST="$APP" "$ROOT/macos/build_app.sh"

echo "==> 生成极简背景"
BACKGROUND=""
if "$DMGPY" -c "import PIL" >/dev/null 2>&1; then
  "$DMGPY" - "$WORK/bg.png" <<'PY'
import sys
from PIL import Image, ImageDraw, ImageFont

W, H = 600, 360
img = Image.new("RGB", (W, H), "#F7F7FA")
d = ImageDraw.Draw(img)

# 中间一个细箭头，指向 Applications
cy = 168
d.line([(252, cy), (344, cy)], fill="#C7C7CE", width=3)
d.line([(330, cy - 10), (344, cy), (330, cy + 10)], fill="#C7C7CE", width=3)

# 底部一行小字（依次尝试可用的系统中文字体；都失败则跳过）
font = None
for path in ("/System/Library/Fonts/PingFang.ttc",
             "/System/Library/Fonts/STHeiti Light.ttc",
             "/System/Library/Fonts/Hiragino Sans GB.ttc",
             "/System/Library/Fonts/Supplemental/Songti.ttc"):
    try:
        font = ImageFont.truetype(path, 15)
        break
    except Exception:
        pass
if font is not None:
    text = "拖到 Applications 即可安装"
    box = d.textbbox((0, 0), text, font=font)
    tw = box[2] - box[0]
    d.text(((W - tw) / 2, 290), text, fill="#8A8A92", font=font)

img.save(sys.argv[1])
PY
  BACKGROUND="$WORK/bg.png"
fi

echo "==> 写 dmgbuild 配置"
SETTINGS="$WORK/settings.py"
{
  echo "files = [r\"$APP\"]"
  echo "symlinks = {'Applications': '/Applications'}"
  if [ -n "$BACKGROUND" ]; then
    echo "background = r\"$BACKGROUND\""
  fi
  echo "window_rect = ((120, 120), (600, 360))"
  echo "default_view = 'icon-view'"
  echo "icon_size = 128"
  echo "text_size = 13"
  echo "icon_locations = {"
  echo "  '$APPNAME.app': (160, 168),"
  echo "  'Applications': (440, 168),"
  echo "}"
} > "$SETTINGS"

echo "==> 打包 DMG"
rm -f "$OUT"
"$DMGBUILD" -s "$SETTINGS" "$VOLNAME" "$OUT"
echo "    $OUT ($(du -h "$OUT" | cut -f1))"
