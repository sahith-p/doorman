#!/bin/bash
# Builds a universal Doorman.app and wraps it in a disk image to hand to someone else: dist/Doorman-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

UNIVERSAL=1 scripts/build-app.sh
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build/Doorman.app/Contents/Info.plist)"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R build/Doorman.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read me first.txt" <<'TEXT'
Doorman

1. Drag Doorman onto Applications.
2. Open it. macOS will say it can't check the app, because Doorman isn't signed by a paid
   Apple developer account. Click Done, then go to System Settings, Privacy & Security,
   scroll down, and click Open Anyway.
3. A key appears in your menu bar. Click it, then Accounts and activity, and follow Get started.
TEXT

mkdir -p dist
DMG="dist/Doorman-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname "Doorman" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
hdiutil verify -quiet "$DMG"
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
