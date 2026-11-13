#!/bin/bash
# Builds BoseControl.app with only the Command Line Tools (no Xcode project).
set -e
cd "$(dirname "$0")"

APP=BoseControl.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -parse-as-library -swift-version 5 BoseControl.swift \
  -o "$APP/Contents/MacOS/BoseControl" \
  -framework SwiftUI -framework IOBluetooth

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.bosecontrol</string>
  <key>CFBundleName</key><string>BoseControl</string>
  <key>CFBundleExecutable</key><string>BoseControl</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>BoseControl talks to your headphones over Bluetooth to switch noise modes.</string>
</dict>
</plist>
EOF

xattr -cr "$APP"
codesign --force --sign - "$APP"
echo "Built $APP — run: open $APP"