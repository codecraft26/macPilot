#!/usr/bin/env bash
# One-command release: build, DMG, EdDSA-sign the DMG with the Sparkle key in your login Keychain,
# and add the release to appcast.xml (keeping the newest 3 items whose DMGs still exist in releases/).
#
#   scripts/release.sh                 # uses the version in Resources/Info.plist
#   SIGN_IDENTITY=… NOTARY_PROFILE=… scripts/release.sh   # Developer ID + notarization, as in package.sh
#
# First time only: create the update signing key (stored in your login Keychain, never in the repo):
#   "$SPARKLE_BIN/generate_keys"
# This script then puts the matching public key into Info.plist (SUPublicEDKey) if it isn't there yet.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SPARKLE_VERSION="2.10.1"   # keep in sync with Package.swift
SPARKLE_BIN="${SPARKLE_BIN:-$HOME/Library/Caches/MacPilot/sparkle-$SPARKLE_VERSION/bin}"
# Feed and downloads are served from the main branch; switch BASE_URL to GitHub Releases later if you like.
BASE_URL="${BASE_URL:-https://raw.githubusercontent.com/codecraft26/macPilot/main}"
FEED_URL="$BASE_URL/appcast.xml"
PLIST="$ROOT/Resources/Info.plist"

if [ ! -x "$SPARKLE_BIN/sign_update" ]; then
  echo "Getting Sparkle $SPARKLE_VERSION tools…"
  mkdir -p "$(dirname "$SPARKLE_BIN")"
  TMP="$(mktemp -d)"
  curl -fsSL -o "$TMP/sparkle.tar.xz" "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
  tar -xf "$TMP/sparkle.tar.xz" -C "$(dirname "$SPARKLE_BIN")"
  rm -rf "$TMP"
fi

# The public key must match the private key in the Keychain (generate_keys -p prints only the public key).
PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null || true)"
if [ -z "$PUBLIC_KEY" ]; then
  echo "No Sparkle signing key in your login Keychain yet. Run once: \"$SPARKLE_BIN/generate_keys\"" >&2
  exit 1
fi
CURRENT_KEY="$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$PLIST" 2>/dev/null || true)"
if [ "$CURRENT_KEY" != "$PUBLIC_KEY" ]; then
  if [ -n "$CURRENT_KEY" ] && [ "${ALLOW_KEY_CHANGE:-}" != "1" ]; then
    echo "Info.plist has a different SUPublicEDKey than your Keychain key. Installed copies would reject this update." >&2
    echo "If you really rotated the key, rerun with ALLOW_KEY_CHANGE=1." >&2
    exit 1
  fi
  /usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "$PLIST" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $PUBLIC_KEY" "$PLIST"
  echo "Set SUPublicEDKey in Info.plist."
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")"

"$ROOT/scripts/package.sh"

DMG="$ROOT/build/MacPilot-$VERSION.dmg"
mkdir -p "$ROOT/releases"
cp "$DMG" "$ROOT/releases/"

# Prints: sparkle:edSignature="…" length="…"  (signs with the Keychain key; the key itself is never printed).
SIGNATURE_LINE="$("$SPARKLE_BIN/sign_update" "$ROOT/releases/MacPilot-$VERSION.dmg")"
SIGNATURE="$(echo "$SIGNATURE_LINE" | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')"
LENGTH="$(echo "$SIGNATURE_LINE" | sed -E 's/.*length="([0-9]+)".*/\1/')"

"$ROOT/build/MacPilot.app/Contents/MacOS/MacPilot" --update-appcast \
  --appcast "$ROOT/appcast.xml" --version "$VERSION" --build "$BUILD" \
  --url "$BASE_URL/releases/MacPilot-$VERSION.dmg" --length "$LENGTH" --signature "$SIGNATURE" \
  --feed "$FEED_URL" --releases-dir "$ROOT/releases" --changelog "$ROOT/CHANGELOG.md"

echo
echo "Release $VERSION ready: releases/MacPilot-$VERSION.dmg and appcast.xml."
echo "Users get it once both are on the main branch ($FEED_URL)."
