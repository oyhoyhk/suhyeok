#!/bin/bash
# Build the phone app and hand it to 수혁 on this Mac, which offers it to paired phones as an update.
#   ./publish.sh   → versionCode = minutes since 2026-01-01 (always increases), versionName = build time
set -euo pipefail
cd "$(dirname "$0")"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}"
# Base pinned to midnight: `date -j -f %Y-%m-%d` fills the missing time with now, freezing the code all day.
CODE=$(( ($(date +%s) - $(date -j -f "%Y-%m-%d %H:%M:%S" "2026-01-01 00:00:00" +%s)) / 60 ))
NAME="$(date +%Y.%m.%d\ %H:%M)"
./gradlew -q assembleDebug -PversionCode="$CODE" -PversionName="$NAME"
OUT="$HOME/Library/Application Support/Suhyeok/android"
mkdir -p "$OUT"
cp app/build/outputs/apk/debug/app-debug.apk "$OUT/suhyeok.apk.tmp"
mv "$OUT/suhyeok.apk.tmp" "$OUT/suhyeok.apk"   # whole file or nothing for a phone downloading now
SHA=$(shasum -a 256 "$OUT/suhyeok.apk" | cut -d' ' -f1)
printf '{"versionCode":%d,"versionName":"%s","sha256":"%s","notes":"%s"}\n' "$CODE" "$NAME" "$SHA" "$(git log -1 --format=%s | sed 's/"/\\"/g')" > "$OUT/version.json"
echo "published $NAME ($CODE) → $OUT"
