#!/bin/bash
# 扫描引擎 JVM 回归测试：不需要 Android 设备 / 模拟器。
set -euo pipefail
cd "$(dirname "$0")"
OUT="$(pwd)/build"
rm -rf "$OUT"
mkdir -p "$OUT"
javac --release 8 -encoding UTF-8 -d "$OUT" \
  ../java/com/jpruby/clearpaper/GrayMath.java \
  ../java/com/jpruby/clearpaper/PdfWrite.java \
  EngineTest.java
java -cp "$OUT" EngineTest "${1:-/tmp/clearpaper-engine-test.pdf}"
