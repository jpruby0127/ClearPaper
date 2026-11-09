#!/bin/bash
# 为 Python 参考引擎建一个隔离的 venv 并装好依赖。
# 用法：bash python/setup.sh
set -eu
cd "$(dirname "${BASH_SOURCE[0]}")"
VENV="${SCANPDF_VENV:-$PWD/.venv}"
python3 -m venv "$VENV"
"$VENV/bin/python" -m pip install -q --upgrade pip
"$VENV/bin/python" -m pip install -q pymupdf numpy pillow scipy
echo "已建好环境：$VENV"
echo "用这个解释器跑 CLI："
echo "  SCANPDF_PY=$VENV/bin/python ./bin/scanpdf 某试卷.pdf"
