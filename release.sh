#!/bin/bash
# Build 수혁.app and pack it for a GitHub release: dist/suhyeok-<version>-arm64.zip (+ sha256 for the formula).
set -euo pipefail
cd "$(dirname "$0")"
VERSION="$(cat VERSION)"
./build.sh
mkdir -p dist
ZIP="dist/suhyeok-$VERSION-arm64.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "수혁.app" "$ZIP"   # ditto keeps the bundle's signature and metadata
shasum -a 256 "$ZIP"
