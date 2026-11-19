#!/usr/bin/env bash
# Builds Notch.app into ./build.
#   scripts/build-app.sh            this Mac's architecture
#   scripts/build-app.sh --open     build, install into /Applications, relaunch from there
#   scripts/build-app.sh --share    a universal build (Apple Silicon + Intel), zipped into ./dist with a how-to-open note
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-}"
if [[ "$MODE" == "--share" ]]; then
  swift build -c release --product Notch --arch arm64 --arch x86_64
  BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
else
  swift build -c release --product Notch
  BIN_DIR="$(swift build -c release --show-bin-path)"
fi

APP="build/Notch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Notch" "$APP/Contents/MacOS/Notch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature by default. Set SIGN_IDENTITY to a Developer ID certificate to sign for real
# (that also keeps the calendar permission across rebuilds; an ad-hoc grant is tied to this exact build).
codesign --force --options runtime --entitlements Resources/Notch.entitlements --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Notch"))"

if [[ "$MODE" == "--open" ]]; then
  # One installed copy, one running copy: replace /Applications/Notch.app and launch that.
  pkill -x Notch 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/Notch.app
  ditto "$APP" /Applications/Notch.app
  LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  "$LSREGISTER" -u "$PWD/$APP" >/dev/null 2>&1 || true   # so notch:// links go to the installed copy
  "$LSREGISTER" -f /Applications/Notch.app
  open /Applications/Notch.app
  echo "Installed /Applications/Notch.app"
elif [[ "$MODE" == "--share" ]]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
  mkdir -p dist
  ZIP="dist/Notch-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Zipped $ZIP"

  # The note goes next to the zip, not inside it: macOS blocks an unnotarized app before
  # anyone can read what's packed with it. (A disk image is worse until the app is notarized:
  # macOS blocks the image itself, then the app, so it's two approvals instead of one.)
  cp "Resources/share/How to open Notch.txt" dist/
  echo "Note dist/How to open Notch.txt"
fi
