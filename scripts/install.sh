#!/bin/bash
# Copies the built app to ~/Applications and opens it. The app registers its Chrome native host when it starts.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="$HOME/Applications/Doorman.app"
osascript -e 'tell application "Doorman" to quit' >/dev/null 2>&1 || true
pkill -x Doorman >/dev/null 2>&1 || true
sleep 1
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R build/Doorman.app "$DEST"
# macOS can refuse to open it for a moment right after the old copy quits.
for attempt in 1 2 3 4 5; do
  open "$DEST" 2>/dev/null && break
  sleep 1
done
cat <<MSG

Doorman is running. Look for the key in your menu bar.

To let an agent use it, add its MCP server. For Claude Code:

  claude mcp add --scope user doorman -- "$DEST/Contents/MacOS/doorman-mcp"

Then see TESTING.md.
MSG
