#!/bin/bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
APP=${PAIRDESK_DISTRIBUTION_APP:-"$ROOT/dist/PairDesk.app"}
INFO="$APP/Contents/Info.plist"
PLIST_TOOL=${PAIRDESK_PLIST_TOOL:-/usr/libexec/PlistBuddy}
[[ -x "$APP/Contents/MacOS/PairDesk" ]] || { echo 'Build the app first' >&2; exit 1; }
[[ -x "$PLIST_TOOL" ]] || { echo "Plist reader not found: $PLIST_TOOL" >&2; exit 1; }
VERSION=$("$PLIST_TOOL" -c 'Print :CFBundleShortVersionString' "$INFO")
BUILD=$("$PLIST_TOOL" -c 'Print :CFBundleVersion' "$INFO")
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid app version: $VERSION" >&2; exit 1; }
[[ "$BUILD" =~ ^[0-9]+$ ]] || { echo "Invalid app build number: $BUILD" >&2; exit 1; }
OUTPUT=${PAIRDESK_DMG_OUTPUT:-"$ROOT/dist/PairDesk-$VERSION-build$BUILD-test.dmg"}
[[ "$OUTPUT" == *.dmg ]] || { echo 'DMG output path must end in .dmg' >&2; exit 1; }
if [[ -e "$OUTPUT" || -e "$OUTPUT.sha256" ]]; then
  echo "Refusing to overwrite an existing installer or checksum: $OUTPUT" >&2
  echo 'Increment CFBundleVersion or choose a new PAIRDESK_DMG_OUTPUT path.' >&2
  exit 1
fi
codesign --verify --deep --strict "$APP"
STAGING=$(mktemp -d "$ROOT/.cache/dmg.XXXXXX")
TEMP_OUTPUT="${OUTPUT%.dmg}.tmp.$$.dmg"
trap 'rm -rf "$STAGING"; rm -f "$TEMP_OUTPUT"' EXIT
mkdir -p "$(dirname "$OUTPUT")"
ditto "$APP" "$STAGING/PairDesk.app"
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/Read me first.txt" <<'TEXT'
PairDesk — internal macOS pairing app

1. If PairDesk is open, quit it first.
2. Drag PairDesk.app onto Applications. If asked, choose Replace; you do not
   need to uninstall or move the previous copy to the Bin.
3. Eject this disk image and open the Applications copy.
4. Sign in using the account created by your team administrator.
5. PairDesk registers automatic startup at first launch from Applications.
   You can turn Start at login off using its menu-bar menu or Account settings.
   macOS may require approval in System Settings > General > Login Items.
6. For calls, allow microphone access when requested. To share, choose a
   display in the macOS screen-sharing picker; no Screen Recording setting is
   needed. Camera video is optional; allow camera access when you turn it on.
   To let teammates control your Mac, enable PairDesk in Accessibility.
7. PairDesk lives in the top-right menu bar. Click its icon to call an online
   teammate; they accept. Click another available teammate to add them.
   Share screen opens Apple's system picker. A shared display allows call
   participants to control it when Accessibility access is enabled.
   Stop control in the menu bar or press Control+Option+Escape.
   Permissions setup in the gear menu opens the relevant macOS Settings pages.
   A remote screen opens a large viewer with a Full screen button.
   Hanging up ends a two-person call for both people.

This file may be a development/test build and is not notarized. A test build
is only for a tester who independently trusts the source and has verified the
separate SHA-256 checksum. After trying to open it, macOS may allow a one-app
exception in System Settings > Privacy & Security > Open Anyway. Proceed only
if you trust this exact build. Do not disable Gatekeeper or remove quarantine.
Only a Developer ID signed and notarized release is suitable for normal team
distribution.

Voice, optional camera video, and screen sharing. Transcription is optional
and local. Startup does not activate the microphone, camera, sharing, remote
control or transcription.
TEXT
hdiutil create -volname PairDesk -srcfolder "$STAGING" -format UDZO "$TEMP_OUTPUT"
hdiutil verify "$TEMP_OUTPUT"
mv -n "$TEMP_OUTPUT" "$OUTPUT"
if [[ -e "$TEMP_OUTPUT" ]]; then
  echo "Refusing to overwrite an installer created concurrently: $OUTPUT" >&2
  exit 1
fi
shasum -a 256 "$OUTPUT" > "$OUTPUT.sha256"
echo "Installer created: $OUTPUT"
