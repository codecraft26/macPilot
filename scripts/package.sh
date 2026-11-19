#!/usr/bin/env bash
# Builds MacPilot and packages it for another Mac as build/MacPilot.zip (and build/MacPilot.dmg).
#
#   scripts/package.sh                      # universal, ad-hoc signed (recipient must allow it once, see README)
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=macpilot scripts/package.sh
#                                           # signed + notarized: opens on any Mac without warnings
#
# NOTARY_PROFILE is a keychain profile created once with:
#   xcrun notarytool store-credentials macpilot --apple-id you@example.com --team-id TEAMID
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

"$ROOT/scripts/build-app.sh" release

APP="$ROOT/build/MacPilot.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
ZIP="$ROOT/build/MacPilot-$VERSION.zip"
DMG="$ROOT/build/MacPilot-$VERSION.dmg"
rm -f "$ZIP" "$DMG"

codesign --verify --deep --strict "$APP"
echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/MacPilot")"
echo "Gatekeeper: $(spctl -a -vv "$APP" 2>&1 | head -1)"
if [ -z "${SIGN_IDENTITY:-}" ]; then
  echo "  (Ad-hoc signed: on another Mac, allow it once — see README \"Installing on another Mac\".)"
fi

# ditto keeps the code signature, permissions and bundle structure intact (Finder zips and some
# upload services can break them, which makes macOS report the app as "damaged").
ditto -c -k --keepParent "$APP" "$ZIP"

if [ -n "${SIGN_IDENTITY:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "Submitting for notarization…"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
fi

# Disk image with an Applications shortcut for drag-to-install.
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "MacPilot" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
fi

echo "Packaged:"
echo "  $ZIP"
echo "  $DMG"
