#!/bin/bash
# Builds Discette.app from the Swift package. Usage: scripts/bundle.sh [release|debug]
# Signs ad hoc for local runs. Developer ID signing and notarization come in replica-deploy.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/Discette.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Discette" "$APP/Contents/MacOS/Discette"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - --options runtime --entitlements Resources/Discette.entitlements "$APP"
codesign --verify --strict "$APP"
echo "$APP"
