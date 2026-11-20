#!/usr/bin/env bash
# The Mac App Store edition of Notch: universal, sandboxed, and (once the certificates exist)
# signed for distribution and packaged as a .pkg for Transporter.
#
# What it looks for, all optional, so the same script works before and after account setup:
#   Resources/AppStore/embedded.provisionprofile   your Mac App Store profile for com.dineshrevunuru.notch
#   An "Apple Distribution" (or "3rd Party Mac Developer Application") certificate in the keychain
#   A "Mac Installer Distribution" (or "3rd Party Mac Developer Installer") certificate in the keychain
#   TEAM_ID (default 39B92NB2W2)
#
# NOTCH_TEST=1 builds build/NotchTest.app under the app ID com.dineshrevunuru.notch.sandboxtest,
# without the data-migration manifest, so trying the sandbox can never move your real tasks.
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM_ID="${TEAM_ID:-39B92NB2W2}"
BUNDLE_ID="com.dineshrevunuru.notch"
APP="build/Notch-AppStore.app"
if [[ "${NOTCH_TEST:-}" == "1" ]]; then
  BUNDLE_ID="com.dineshrevunuru.notch.sandboxtest"
  APP="build/NotchTest.app"
fi

swift build -c release --product Notch --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Notch" "$APP/Contents/MacOS/Notch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$PLIST"
# This edition never asks browsers for their tabs, so it doesn't carry the Apple Events prompt text.
/usr/libexec/PlistBuddy -c "Delete :NSAppleEventsUsageDescription" "$PLIST" 2>/dev/null || true

# App Store Connect checks which Xcode and SDK built the app from these keys. Xcode writes them;
# a SwiftPM build doesn't, so stamp them from the toolchain that just built the binary.
XCODE_VERSION="$(xcodebuild -version | awk 'NR==1 {print $2}')"          # e.g. 27.2
IFS=. read -r XC_MAJOR XC_MINOR XC_PATCH <<< "$XCODE_VERSION"
DT_XCODE="$(printf '%02d%d%d' "$XC_MAJOR" "${XC_MINOR:-0}" "${XC_PATCH:-0}")"   # e.g. 2720
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
SDK_BUILD="$(xcrun --sdk macosx --show-sdk-build-version)"
for entry in \
  "CFBundleSupportedPlatforms array" \
  "DTCompiler string com.apple.compilers.llvm.clang.1_0" \
  "DTPlatformName string macosx" \
  "DTPlatformVersion string $SDK_VERSION" \
  "DTPlatformBuild string $SDK_BUILD" \
  "DTSDKName string macosx$SDK_VERSION" \
  "DTSDKBuild string $SDK_BUILD" \
  "DTXcode string $DT_XCODE" \
  "DTXcodeBuild string $(xcodebuild -version | awk 'NR==2 {print $3}')" \
  "BuildMachineOSBuild string $(sw_vers -buildVersion)"; do
  key="${entry%% *}"
  /usr/libexec/PlistBuddy -c "Delete :$key" "$PLIST" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :$entry" "$PLIST"
done
/usr/libexec/PlistBuddy -c "Add :CFBundleSupportedPlatforms:0 string MacOSX" "$PLIST"
if [[ "${NOTCH_TEST:-}" == "1" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleName NotchTest" -c "Set :CFBundleDisplayName NotchTest" "$PLIST"
  /usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$PLIST" 2>/dev/null || true
else
  cp Resources/AppStore/container-migration.plist "$APP/Contents/Resources/container-migration.plist"
fi

# Signing: distribution if the certificate and profile exist, ad hoc otherwise (for local testing only).
DIST_ID="$(security find-identity -v -p codesigning | grep -E '"(Apple Distribution|3rd Party Mac Developer Application)' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"
PROFILE="Resources/AppStore/embedded.provisionprofile"
ENT="$(mktemp -t notch-entitlements).plist"
cp Resources/AppStore/Notch.entitlements "$ENT"
if [[ -n "$DIST_ID" && -f "$PROFILE" && "${NOTCH_TEST:-}" != "1" ]]; then
  cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
  /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM_ID.$BUNDLE_ID" "$ENT"
  /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$ENT"
  SIGN="$DIST_ID"
else
  SIGN="-"
fi
codesign --force --options runtime --entitlements "$ENT" --sign "$SIGN" "$APP"
rm -f "$ENT"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Notch")), signed: ${SIGN/-/ad hoc (testing only)}"

if [[ "$SIGN" == "-" ]]; then
  [[ "${NOTCH_TEST:-}" == "1" ]] || echo "No .pkg yet: needs an Apple Distribution certificate and $PROFILE (see docs/app-store/CHECKLIST.md)."
  exit 0
fi

INSTALLER_ID="$(security find-identity -v | grep -E '"(Mac Installer Distribution|3rd Party Mac Developer Installer)' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"
if [[ -z "$INSTALLER_ID" ]]; then
  echo "App is signed, but no installer certificate found: add a Mac Installer Distribution certificate to make the .pkg."
  exit 1
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
mkdir -p dist
PKG="dist/Notch-$VERSION-AppStore.pkg"
productbuild --component "$APP" /Applications --sign "$INSTALLER_ID" "$PKG"
echo "Package $PKG — upload it with Transporter."
