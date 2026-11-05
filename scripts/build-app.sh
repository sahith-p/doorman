#!/bin/bash
# Builds Doorman.app into build/. Ad hoc signed, since this project has no Apple Developer ID, so macOS
# treats every rebuild as a new app and asks again for Keychain and Accessibility access.
# UNIVERSAL=1 builds for both Apple silicon and Intel, which `make package` uses.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHS=()
if [ "${UNIVERSAL:-}" = "1" ]; then ARCHS=(--arch arm64 --arch x86_64); fi
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --product Doorman
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --product doorman-mcp
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --product doorman-host
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

APP=build/Doorman.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/extension"
cp "$BIN/Doorman" "$BIN/doorman-mcp" "$BIN/doorman-host" "$APP/Contents/MacOS/"
cp -R extension/fill extension/apple-bridge "$APP/Contents/Resources/extension/"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Doorman</string>
  <key>CFBundleDisplayName</key><string>Doorman</string>
  <key>CFBundleIdentifier</key><string>ai.doorman.app</string>
  <key>CFBundleExecutable</key><string>Doorman</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Personal build</string>
</dict>
</plist>
PLIST
# Inner binaries first, then the bundle.
# Hardened runtime: another program can't inject code into Doorman with DYLD_INSERT_LIBRARIES or attach to it.
codesign --force --options runtime --sign - "$APP/Contents/MacOS/doorman-mcp"
codesign --force --options runtime --sign - "$APP/Contents/MacOS/doorman-host"
codesign --force --options runtime --sign - "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"
