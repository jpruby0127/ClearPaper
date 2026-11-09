#!/bin/bash
# 在 macOS / Linux 上组装「Windows 免安装便携包」：
#   dist/ScanClean-Windows-portable.zip
#
# 原理：Windows 嵌入式 CPython + PyPI 上的 win_amd64 轮子（pymupdf/numpy/Pillow/scipy），
# 全部解包进 portable 目录，配一个拖拽用的 ScanClean.bat。无需在 Windows 上编译。
#
# 用法：./windows/build_portable.sh
set -eu

PYVER="${PYVER:-3.12.10}"      # Windows 嵌入式 Python 版本
WHEELPY="${WHEELPY:-312}"      # 轮子 ABI 版本（3.12 -> 312）
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DIST="$ROOT/dist"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PKG="$WORK/ScanClean"
mkdir -p "$PKG/python" "$PKG/app" "$DIST"

echo "==> 1/4 下载 Windows 嵌入式 Python $PYVER"
EMBED="$WORK/python-embed.zip"
curl -fsSL -o "$EMBED" "https://www.python.org/ftp/python/$PYVER/python-$PYVER-embed-amd64.zip"
unzip -q "$EMBED" -d "$PKG/python"
echo "    $(ls "$PKG/python" | tr '\n' ' ')"

echo "==> 2/4 安装 win_amd64 依赖轮子到 site-packages"
SITE="$PKG/python/Lib/site-packages"
mkdir -p "$SITE"
python3 -m pip install --quiet --upgrade --target "$SITE" \
  --platform win_amd64 --python-version "$WHEELPY" \
  --only-binary=:all: --no-compile \
  pymupdf numpy pillow scipy
# 瘦身：测试目录、缓存、元数据对运行无影响
find "$SITE" -type d \( -name tests -o -name test -o -name __pycache__ -o -name '*.dist-info' \) \
  -prune -exec rm -rf {} + 2>/dev/null || true
echo "    $(du -sh "$SITE" | cut -f1)  site-packages"

echo "==> 3/4 配置路径与拷贝应用文件"
# 让嵌入式解释器能找到 site-packages：重写包内自带的 `pythonXY._pth`
ZIPPED="$(basename "$(ls "$PKG/python"/python*.zip | head -1)")"
for pth in "$PKG/python"/*._pth; do
  [ -f "$pth" ] || continue
  printf '%s\n.\nLib\\site-packages\nimport site\n' "$ZIPPED" > "$pth"
  echo "    已配置 $(basename "$pth")（stdlib=${ZIPPED}）"
done

cp "$ROOT/python/scanpdf/engine.py"      "$PKG/app/engine.py"
cp "$ROOT/python/scanpdf/clean_scan.py"  "$PKG/app/clean_scan.py"
cp "$ROOT/python/scanpdf/verify.py"      "$PKG/app/verify.py"
cp "$HERE/scanpdf.py"                    "$PKG/app/scanpdf.py"
cp "$HERE/ScanClean.bat"                 "$PKG/ScanClean.bat"
cp "$HERE/README-Windows.txt"            "$PKG/README-Windows.txt"
echo "    app: $(ls "$PKG/app" | tr '\n' ' ')"

echo "==> 4/4 打包 zip"
OUT="$DIST/ScanClean-Windows-portable.zip"
rm -f "$OUT"
( cd "$WORK" && zip -qrX "$OUT" ScanClean )
echo "    $OUT ($(du -h "$OUT" | cut -f1))"
echo
echo "完成。Windows 上解压后，把 PDF 拖到 ScanClean.bat 上即可。"
