#!/usr/bin/env bash
# Builds MacPilot with SwiftPM and wraps it in a signed .app bundle at build/MacPilot.app.
# Usage: scripts/build-app.sh [debug|release]
# Set SIGN_IDENTITY="Apple Development: You (TEAMID)" for a stable signature
# (otherwise the app is ad-hoc signed and Keychain may ask again after each rebuild).
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="$ROOT/build/MacPilot.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/MacPilot" "$APP/Contents/MacOS/MacPilot"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
  cp -R "$bundle" "$APP/Contents/Resources/"
done

codesign --force --sign "${SIGN_IDENTITY:--}" \
  --entitlements "$ROOT/Resources/MacPilot.entitlements" \
  "$APP"

# Make Finder and the Dock pick up the new icon.
touch "$APP"

echo "Built $APP"
echo "Run it with: open \"$APP\""
