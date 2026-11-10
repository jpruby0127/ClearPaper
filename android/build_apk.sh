#!/bin/bash
# ClearPaper · Android
# 零第三方依赖构建：aapt2 -> javac -> d8 -> zipalign -> apksigner
# 不需要 Gradle / AndroidX / Maven 网络，Android SDK build-tools 就够了。
set -euo pipefail
cd "$(dirname "$0")"
HERE=$(pwd)
OUT="$HERE/build"
DIST="$HERE/../dist"

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
BT=$(ls -d "$SDK"/build-tools/* 2>/dev/null | sort -V | tail -1)
JAR=$(ls -d "$SDK"/platforms/android-3* 2>/dev/null | sort -V | tail -1)/android.jar
for p in "$BT/aapt2" "$BT/d8" "$BT/zipalign" "$BT/apksigner" "$JAR"; do
  [ -e "$p" ] || { echo "missing: $p"; exit 1; }
done

VERSION_NAME="1.5.0"
VERSION_CODE="10"
APK_NAME="ClearPaper-Android-${VERSION_NAME}.apk"

rm -rf "$OUT"
mkdir -p "$OUT/compiled" "$OUT/gen" "$OUT/classes" "$OUT/dex" "$DIST"

echo "[1/7] aapt2 compile resources"
"$BT/aapt2" compile --dir "$HERE/res" -o "$OUT/compiled/"

echo "[2/7] aapt2 link + R.java"
FLATS=$(find "$OUT/compiled" -name '*.flat' | sort | tr '\n' ' ')
# shellcheck disable=SC2086
"$BT/aapt2" link -o "$OUT/base.apk" -I "$JAR" \
  --manifest "$HERE/AndroidManifest.xml" --java "$OUT/gen" \
  --min-sdk-version 26 --target-sdk-version 34 \
  --version-code "$VERSION_CODE" --version-name "$VERSION_NAME" \
  $FLATS

echo "[3/7] javac"
SRCS=$(find "$HERE/java" "$OUT/gen" -name '*.java' | sort | tr '\n' ' ')
# shellcheck disable=SC2086
javac --release 8 -encoding UTF-8 -nowarn -cp "$JAR" -d "$OUT/classes" $SRCS

echo "[4/7] d8 -> classes.dex"
CLASSES=$(find "$OUT/classes" -name '*.class' | sort | tr '\n' ' ')
# shellcheck disable=SC2086
"$BT/d8" --lib "$JAR" --min-api 26 --output "$OUT/dex" $CLASSES
(cd "$OUT/dex" && zip -q -j "$OUT/base.apk" classes.dex)

echo "[5/7] zipalign"
"$BT/zipalign" -p -f 4 "$OUT/base.apk" "$OUT/unsigned.apk"

echo "[6/7] apksigner"
KS="$HERE/clearpaper-release.jks"
if [ ! -f "$KS" ]; then
  keytool -genkeypair -keystore "$KS" -storetype PKCS12 \
    -storepass clearpaper -keypass clearpaper -alias clearpaper \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=jpruby, OU=ClearPaper, O=jpruby, L=Beijing, C=CN" >/dev/null 2>&1
fi
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:clearpaper --key-pass pass:clearpaper \
  --v1-signing-enabled true --v2-signing-enabled true \
  --out "$OUT/signed.apk" "$OUT/unsigned.apk"
"$BT/apksigner" verify --verbose "$OUT/signed.apk" | head -12

echo "[7/7] deliver"
cp "$OUT/signed.apk" "$DIST/$APK_NAME"
"$BT/aapt2" dump badging "$DIST/$APK_NAME" | head -6
ls -lh "$DIST/$APK_NAME"
echo "OK -> $DIST/$APK_NAME"
