#!/bin/bash
# Build the Play flavor as a signed AAB and upload it to Google Play through the Publishing API.
#   ./play-release.sh             → internal testing track
#   ./play-release.sh alpha       → closed testing ("alpha" is the API name of the default closed track)
#   ./play-release.sh production  → production (personal accounts: only after 12 testers × 14 days of closed testing)
#   ./play-release.sh alpha --release-status draft → extra args go to Gradle Play Publisher
#   ./play-release.sh --bundle    → build the AAB only (the first upload goes through Play Console by hand)
# Needs ~/keys/suhyeok-release.properties (upload key) and ~/keys/suhyeok-play.json (service account). See PLAY.md.
set -euo pipefail
cd "$(dirname "$0")"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}"
[ -f ~/keys/suhyeok-release.properties ] || { echo "no upload key: ~/keys/suhyeok-release.properties"; exit 1; }
# Same clock-based code as publish.sh, so it always increases.
CODE=$(( ($(date +%s) - $(date -j -f "%Y-%m-%d %H:%M:%S" "2026-01-01 00:00:00" +%s)) / 60 ))
NAME="$(date +%Y.%m.%d.%H%M)"
if [ "${1:-}" = "--bundle" ]; then
  ./gradlew -q bundlePlayRelease -PversionCode="$CODE" -PversionName="$NAME"
  echo "built app/build/outputs/bundle/playRelease/app-play-release.aab ($NAME, $CODE)"
  exit 0
fi
[ -f ~/keys/suhyeok-play.json ] || { echo "no service account: ~/keys/suhyeok-play.json"; exit 1; }
./gradlew -q publishPlayReleaseBundle --track "${1:-internal}" "${@:2}" -PversionCode="$CODE" -PversionName="$NAME"
echo "uploaded $NAME ($CODE) to ${1:-internal}"
