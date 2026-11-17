#!/usr/bin/env bash
# Assembles what the desktop bundle ships (used by CI and local builds; run before `cargo build` / `tauri build`):
#   src-tauri/binaries/suhyeok-server-<target triple>[.exe]   Tauri externalBin sidecar, built from ../server-rs
#   src-tauri/art/                                             art/out + art/roster.json in one folder (as build.sh)
# TARGET_TRIPLE overrides the host triple (cross builds: the server is then built with --target).
set -euo pipefail
cd "$(dirname "$0")/.."
host=$(rustc -vV | sed -n 's/^host: //p')
triple=${TARGET_TRIPLE:-$host}
ext=""
case "$triple" in *windows*) ext=".exe" ;; esac

if [ "$triple" = "$host" ]; then
  (cd server-rs && cargo build --release)
  built="server-rs/target/release/suhyeok-server$ext"
else
  (cd server-rs && cargo build --release --target "$triple")
  built="server-rs/target/$triple/release/suhyeok-server$ext"
fi
mkdir -p desktop/src-tauri/binaries
cp "$built" "desktop/src-tauri/binaries/suhyeok-server-$triple$ext"

rm -rf desktop/src-tauri/art
mkdir -p desktop/src-tauri/art
cp art/roster.json desktop/src-tauri/art/
cp -R art/out/. desktop/src-tauri/art/
echo "sidecar: desktop/src-tauri/binaries/suhyeok-server-$triple$ext"
echo "art: desktop/src-tauri/art ($(find desktop/src-tauri/art -type f | wc -l | tr -d ' ') files)"
