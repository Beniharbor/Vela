#!/bin/bash
# Builds Vela and assembles Vela.app (no Xcode needed — SPM + manual bundling).
# Usage: Scripts/package.sh [debug|release] [install]
#   install: also copy to /Applications and relaunch
set -euo pipefail

CONFIG="${1:-release}"
INSTALL="${2:-}"
if [ "$CONFIG" = "install" ]; then CONFIG="release"; INSTALL="install"; fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/Vela"
APP="build/Vela.app"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Vela"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# SPM resource bundles (e.g. KeyboardShortcuts localizations, WhisperKit resources)
for bundle in .build/"$CONFIG"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

echo "==> Ad-hoc codesign"
codesign --force --deep --sign - "$APP"

echo "==> Done: $ROOT/$APP"

if [ "$INSTALL" = "install" ]; then
  echo "==> Installing to /Applications"
  pkill -f "Vela.app/Contents/MacOS/Vela" 2>/dev/null || true
  ditto "$APP" /Applications/Vela.app
  open /Applications/Vela.app
  echo "==> Installed and relaunched /Applications/Vela.app"
else
  echo "    Run with: open $ROOT/$APP   (or: Scripts/package.sh release install)"
fi
