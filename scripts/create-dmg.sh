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
# Use an explicit build environment so packaging never installs dependencies itself.
DMG_PYTHON=${PAIRDESK_DMG_PYTHON:-"$ROOT/.cache/dmg-venv/bin/python"}
if [[ ! -x "$DMG_PYTHON" ]] || ! "$DMG_PYTHON" -c 'import dmgbuild' 2>/dev/null; then
  echo 'DMG tools missing. With Python 3.10+, run:' >&2
  echo '  python3 -m venv .cache/dmg-venv' >&2
  echo '  .cache/dmg-venv/bin/python -m pip install -r scripts/dmg/requirements.txt' >&2
  exit 1
fi
codesign --verify --deep --strict "$APP"
TEMP_OUTPUT="${OUTPUT%.dmg}.tmp.$$.dmg"
trap 'rm -f "$TEMP_OUTPUT"' EXIT
mkdir -p "$(dirname "$OUTPUT")"
"$DMG_PYTHON" -m dmgbuild -s "$ROOT/scripts/dmg/settings.py" \
  -D "app=$APP" -D "background=$ROOT/scripts/dmg/background.tiff" PairDesk "$TEMP_OUTPUT"
hdiutil verify "$TEMP_OUTPUT"
mv -n "$TEMP_OUTPUT" "$OUTPUT"
if [[ -e "$TEMP_OUTPUT" ]]; then
  echo "Refusing to overwrite an installer created concurrently: $OUTPUT" >&2
  exit 1
fi
shasum -a 256 "$OUTPUT" > "$OUTPUT.sha256"
echo "Installer created: $OUTPUT"
