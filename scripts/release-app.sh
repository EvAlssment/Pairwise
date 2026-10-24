#!/bin/bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$ROOT/dist/PairDesk.app"
IDENTITY=${DEVELOPER_SIGNING_IDENTITY:-}
PROFILE=${PAIRDESK_NOTARY_PROFILE:-}
SERVER=${PAIRDESK_SERVER_URL:-}
python3 - "$SERVER" <<'PYURL'
import sys, urllib.parse
url = urllib.parse.urlsplit(sys.argv[1])
if url.scheme != 'https' or not url.hostname or url.username or url.password or url.query or url.fragment or url.path not in ['', '/']:
    raise SystemExit('Set PAIRDESK_SERVER_URL to the production HTTPS API origin')
PYURL
[[ -n "$IDENTITY" && "$IDENTITY" == 'Developer ID Application:'* ]] || { echo 'Set DEVELOPER_SIGNING_IDENTITY to an installed Developer ID Application identity' >&2; exit 1; }
[[ -n "$PROFILE" ]] || { echo 'Set PAIRDESK_NOTARY_PROFILE to your stored notarytool credential profile' >&2; exit 1; }
security find-identity -v -p codesigning | grep -F -- "\"$IDENTITY\"" >/dev/null || { echo 'Requested Developer ID identity is unavailable' >&2; exit 1; }
[[ -x "$SOURCE/Contents/MacOS/PairDesk" ]] || { echo 'Build the app first' >&2; exit 1; }
OUTPUT=${PAIRDESK_RELEASE_OUTPUT:-"$ROOT/dist/release"}
[[ ! -e "$OUTPUT" ]] || { echo "$OUTPUT already exists; preserve it before producing another release" >&2; exit 1; }
mkdir -p "$(dirname "$OUTPUT")"
STAGING=$(mktemp -d "$(dirname "$OUTPUT")/.pairdesk-release.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/PairDesk.app"
ditto "$SOURCE" "$APP"
/usr/libexec/PlistBuddy -c "Delete :PairDeskServerURL" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :PairDeskServerURL string $SERVER" "$APP/Contents/Info.plist"
for framework in "$APP/Contents/Frameworks/"*.framework; do
  [[ -d "$framework" ]] || continue
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$framework"
done
while IFS= read -r library; do
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$library"
done < <(find "$APP/Contents/Frameworks" -maxdepth 1 -type f -name '*.dylib')
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Resources/whisper/whisper-cli"
codesign --force --options runtime --timestamp --entitlements "$ROOT/macos/Release.entitlements" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
ditto -c -k --keepParent "$APP" "$STAGING/PairDesk-submit.zip"
xcrun notarytool submit "$STAGING/PairDesk-submit.zip" --keychain-profile "$PROFILE" --wait --output-format json > "$STAGING/notarization.json"
python3 - "$STAGING/notarization.json" <<'PY'
import json, sys
with open(sys.argv[1]) as stream:
    result = json.load(stream)
if result.get('status') != 'Accepted':
    print('Notarization was not accepted; inspect the Apple submission log for ID ' + result.get('id', 'unknown'), file=sys.stderr)
    sys.exit(1)
PY
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
rm -f "$STAGING/PairDesk-submit.zip"
ditto -c -k --keepParent "$APP" "$STAGING/PairDesk.zip"
PAIRDESK_DISTRIBUTION_APP="$APP" \
PAIRDESK_DMG_OUTPUT="$STAGING/PairDesk.dmg" \
  bash "$ROOT/scripts/create-dmg.sh"
xcrun notarytool submit "$STAGING/PairDesk.dmg" --keychain-profile "$PROFILE" --wait --output-format json > "$STAGING/dmg-notarization.json"
python3 - "$STAGING/dmg-notarization.json" <<'PY'
import json, sys
with open(sys.argv[1]) as stream:
    result = json.load(stream)
if result.get('status') != 'Accepted':
    print('DMG notarization was not accepted; inspect the Apple submission log for ID ' + result.get('id', 'unknown'), file=sys.stderr)
    sys.exit(1)
PY
xcrun stapler staple "$STAGING/PairDesk.dmg"
xcrun stapler validate "$STAGING/PairDesk.dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$STAGING/PairDesk.dmg"
rm -f "$STAGING/PairDesk.dmg.sha256" "$STAGING/dmg-notarization.json" "$STAGING/notarization.json"
(cd "$STAGING" && shasum -a 256 PairDesk.dmg PairDesk.zip > SHA256SUMS)
mv "$STAGING" "$OUTPUT"
trap - EXIT
echo "Signed, notarized, stapled and assessed release: $OUTPUT/PairDesk.dmg"
