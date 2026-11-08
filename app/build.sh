#!/bin/bash
# 编译并打包成 build/Speakless.app（只需要 Command Line Tools，不需要完整 Xcode）
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN=$(swift build -c release --show-bin-path)/Speakless

APP=build/Speakless.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Speakless"

swift tools/make_icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Speakless</string>
  <key>CFBundleDisplayName</key><string>Speakless</string>
  <key>CFBundleIdentifier</key><string>com.starry.speakless</string>
  <key>CFBundleExecutable</key><string>Speakless</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <key>NSMicrophoneUsageDescription</key><string>Speakless listens through the microphone while you dictate.</string>
</dict>
</plist>
PLIST

# 签名：优先用固定的本地证书 "Speakless Local Signing"（重新编译后系统权限不会丢），没有就退回 ad-hoc
if security find-identity | grep -q "Speakless Local Signing"; then
  codesign --force --deep --sign "Speakless Local Signing" --identifier com.starry.speakless "$APP"
  echo "signed with: Speakless Local Signing"
else
  codesign --force --deep --sign - --identifier com.starry.speakless "$APP"
  echo "signed ad-hoc (permissions must be re-granted after every build)"
fi
echo "OK -> $(pwd)/$APP"

# 加 --install 参数：装进 /Applications，之后 Spotlight（⌘空格）和启动台里都能搜到
if [[ "${1:-}" == "--install" ]]; then
  pkill -x Speakless 2>/dev/null || true
  sleep 1
  rm -rf /Applications/Speakless.app
  cp -R "$APP" /Applications/Speakless.app
  mdimport /Applications/Speakless.app
  echo "Installed -> /Applications/Speakless.app"
fi
