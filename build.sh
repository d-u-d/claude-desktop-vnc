#!/bin/bash
# Сборка WinVNC.app — резидентное приложение в строке меню.
# Этап A: захват окна Claude по таймеру в /tmp/claude_frame.png + статус в меню.
set -e
cd "$(dirname "$0")"

APP=WinVNC.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O Sources/*.swift -o "$APP/Contents/MacOS/WinVNC" \
    -import-objc-header Sources/bridge.h -lz -framework Cocoa

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>WinVNC</string>
  <key>CFBundleIdentifier</key><string>local.winvnc.app</string>
  <key>CFBundleExecutable</key><string>WinVNC</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign "WinVNC Local Dev" --identifier local.winvnc.app "$APP" 2>&1 | tail -1
echo "собрано: $APP"
