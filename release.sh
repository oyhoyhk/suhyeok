#!/bin/bash
# Build 수혁.app and pack it for a GitHub release: dist/suhyeok-<version>-arm64.zip (+ sha256 for the formula).
set -euo pipefail
cd "$(dirname "$0")"
VERSION="$(cat VERSION)"
./build.sh
mkdir -p dist
ZIP="dist/suhyeok-$VERSION-arm64.zip"
rm -f "$ZIP"
ditto -c -k --norsrc --noextattr --keepParent "수혁.app" "$ZIP"  # no ._AppleDouble files: unzip would add them to the bundle and break its seal
shasum -a 256 "$ZIP"
