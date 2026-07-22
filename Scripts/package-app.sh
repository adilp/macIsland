#!/usr/bin/env bash
#
# Package macIsland as a minimal, ad-hoc-signed `.app` bundle.
#
# Why this exists: macIsland is a menu-bar agent that requests Calendar access through
# EventKit. macOS TCC only shows a permission prompt for a process that has an Info.plist
# *usage-description* string and a real app-bundle identity -- a bare `swift run` binary has
# neither, so the "Connect Calendar..." prompt is silently suppressed (the request just
# returns `false`). Running from this bundle fixes that. It also makes `LSUIElement` real
# (no Dock icon) rather than the runtime `setActivationPolicy(.accessory)` fallback.
#
# Ad-hoc signing (the `-` identity) is enough for a local prompt; ship a real Developer ID
# signature for distribution. A rebuild re-signs with a new cdhash, so macOS may re-prompt
# for Calendar access after each rebuild -- fine for dev.
#
# Usage: scripts/package-app.sh [debug|release]   (default: debug)
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_NAME="MacIslandApp"
APP="$ROOT/.build/macIsland.app"

echo "-> building ($CONFIG)..."
swift build -c "$CONFIG" --product "$BIN_NAME"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/$BIN_NAME"

echo "-> assembling app bundle at $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/$BIN_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>               <string>macIsland</string>
    <key>CFBundleDisplayName</key>        <string>macIsland</string>
    <key>CFBundleExecutable</key>         <string>${BIN_NAME}</string>
    <key>CFBundleIdentifier</key>         <string>com.macisland.app</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.1</string>
    <key>CFBundleVersion</key>            <string>1</string>
    <key>LSMinimumSystemVersion</key>     <string>14.0</string>
    <key>LSUIElement</key>                <true/>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>macIsland shows your upcoming meetings on the notch and offers a one-tap Join for video calls.</string>
</dict>
</plist>
PLIST

echo "-> ad-hoc signing"
codesign --force --sign - --timestamp=none "$APP"

echo "OK: built $APP"
