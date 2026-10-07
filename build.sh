#!/bin/bash
# Build release binary and wrap it into 수혁.app (no Xcode project needed).
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${VERSION:-$(cat VERSION)}"
swift build -c release
APP="수혁.app"
rm -rf "$APP" AgentDeck.app  # AgentDeck.app = pre-rename bundle
mkdir -p "$APP/Contents/MacOS"
cp .build/release/AgentDeck "$APP/Contents/MacOS/AgentDeck"
# Processed art (art/out) ships inside the bundle; the app falls back to placeholders without it.
mkdir -p "$APP/Contents/Resources/art"
cp art/roster.json "$APP/Contents/Resources/art/"
[ -d art/out ] && cp -R art/out/ "$APP/Contents/Resources/art/"
[ -f art/out/AppIcon.icns ] && cp art/out/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>수혁</string>
  <key>CFBundleDisplayName</key><string>수혁</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>com.pickuma.agentdeck</string>
  <key>CFBundleExecutable</key><string>AgentDeck</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>대화창에서 말로 에이전트에게 지시하기 위해 마이크를 씁니다.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>말한 내용을 글로 바꿔 지시 입력칸에 넣습니다. 가능하면 이 Mac 안에서만 처리합니다.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "built $(pwd)/$APP"
