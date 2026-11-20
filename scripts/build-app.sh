#!/usr/bin/env bash
# Builds MacPilot with SwiftPM and wraps it in a signed .app bundle at build/MacPilot.app.
# Usage: scripts/build-app.sh [debug|release]
# The release build is universal (Apple silicon + Intel). Set ARCHS="arm64" for a faster single-arch build.
# Set BUILD_DIR to choose a different output directory.
# Set SIGN_IDENTITY="Apple Development: You (TEAMID)" for a stable signature
# (otherwise the app is ad-hoc signed and Keychain may ask again after each rebuild).
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ARCHS="${ARCHS:-$([ "$CONFIG" = "release" ] && echo "arm64 x86_64" || uname -m)}"
ARCH_FLAGS=()
for arch in $ARCHS; do ARCH_FLAGS+=(--arch "$arch"); done

if ! swift build -c "$CONFIG" "${ARCH_FLAGS[@]}"; then
  if [ "${#ARCH_FLAGS[@]}" -gt 2 ]; then
    echo "Universal build failed; building for $(uname -m) only." >&2
    ARCH_FLAGS=(--arch "$(uname -m)")
    swift build -c "$CONFIG" "${ARCH_FLAGS[@]}"
  else
    exit 1
  fi
fi
BIN_DIR="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)"

APP="${BUILD_DIR:-$ROOT/build}/MacPilot.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/MacPilot" "$APP/Contents/MacOS/MacPilot"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
  cp -R "$bundle" "$APP/Contents/Resources/"
done

# A Developer ID identity gets the hardened runtime and a timestamp so the app can be notarized.
SIGN_ARGS=(--force --sign "${SIGN_IDENTITY:--}" --entitlements "$ROOT/Resources/MacPilot.entitlements")
if [ -n "${SIGN_IDENTITY:-}" ]; then
  SIGN_ARGS+=(--options runtime --timestamp)
fi
codesign "${SIGN_ARGS[@]}" "$APP"

# Make Finder and the Dock pick up the new icon.
touch "$APP"

echo "Built $APP"
echo "Run it with: open \"$APP\""
