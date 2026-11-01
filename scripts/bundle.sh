#!/bin/bash
# Builds Discette.app from the Swift package. Usage: scripts/bundle.sh [release|debug] [install|zip]
# "install" replaces /Applications/Discette.app with the new build (quitting the old one first).
# "zip" also writes dist/Discette-<version>.zip, the file attached to GitHub releases.
# Signs ad hoc: not notarized, which would need a paid Apple developer account.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

# Assembled outside Documents: iCloud tags anything it syncs with Finder metadata faster than it
# can be stripped, and codesign rejects that. Library/Caches is also left out of Spotlight, so
# only the installed copy shows up there.
OUT="${DISCETTE_BUILD_DIR:-$HOME/Library/Caches/Discette-build}"
APP="$OUT/Discette.app"
mkdir -p "$OUT"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Discette" "$APP/Contents/MacOS/Discette"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

xattr -cr "$APP"
# Ad hoc signatures name the exact build (its hash), so macOS treated every rebuild as a new app
# and added another "Discette" row to each Privacy & Security list. Naming the bundle ID as the
# requirement keeps one entry, and its permissions, across rebuilds.
codesign --force --sign - --options runtime --entitlements Resources/Discette.entitlements \
    -r='designated => identifier "com.adamwu.Discette"' "$APP"
codesign --verify --strict "$APP"

if [ "${2:-}" = "install" ]; then
    osascript -e 'tell application id "com.adamwu.Discette" to quit' 2>/dev/null || true
    sleep 1
    rm -rf /Applications/Discette.app
    ditto "$APP" /Applications/Discette.app
    codesign --verify --strict /Applications/Discette.app
    APP=/Applications/Discette.app
fi
if [ "${2:-}" = "zip" ]; then
    VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)"
    mkdir -p dist
    ZIP="dist/Discette-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
    APP="$ZIP"
fi
echo "$APP"
