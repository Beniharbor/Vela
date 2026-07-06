#!/bin/bash
# Builds Vela and assembles Vela.app (no Xcode needed — SPM + manual bundling).
# Usage: Scripts/package.sh [debug|release]   (default: release)
set -euo pipefail

CONFIG="${1:-release}"
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
echo "    Run with: open $ROOT/$APP"
