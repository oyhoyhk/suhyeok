#!/bin/bash
# One-command release: build, GitHub release, Homebrew tap update.
#   ./publish.sh 0.1.2 "변경 요약"
set -euo pipefail
cd "$(dirname "$0")"
V="${1:?usage: ./publish.sh <x.y.z> [notes]}"
NOTES="${2:-}"
TAP="${TAP_DIR:-$HOME/projects/homebrew-tap}"
REPO=oyhoyhk/suhyeok
ATTR=$'\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>'

[[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must look like 1.2.3"; exit 1; }
git diff --quiet && git diff --cached --quiet || { echo "commit your changes first"; exit 1; }
# GitHub's CDN keeps serving a replaced asset, so a version is never reused.
if gh release view "v$V" -R "$REPO" >/dev/null 2>&1; then echo "v$V already released — bump the version"; exit 1; fi

echo "$V" > VERSION
./release.sh
ZIP="dist/suhyeok-$V-arm64.zip"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
git commit -qm "release $V$ATTR" VERSION && git push -q

gh release create "v$V" "$ZIP" -R "$REPO" --title "수혁 $V" \
  --notes "${NOTES:+$NOTES$'\n\n'}업데이트: 앱의 업데이트 버튼 또는 \`brew upgrade suhyeok\`"

URL="https://github.com/$REPO/releases/download/v$V/suhyeok-$V-arm64.zip"
for _ in $(seq 1 30); do  # wait until the download serves exactly this zip
  [ "$(curl -sL "$URL" | shasum -a 256 | cut -d' ' -f1)" = "$SHA" ] && break
  sleep 5
done

F="$TAP/Formula/suhyeok.rb"
sed -i '' -E \
  -e "s|url \".*\"|url \"$URL\"|" \
  -e "s|sha256 \".*\"|sha256 \"$SHA\"|" \
  -e "s|version \".*\"|version \"$V\"|" "$F"
git -C "$TAP" commit -qam "suhyeok $V$ATTR" && git -C "$TAP" push -q
echo "published $V  sha256 $SHA"
