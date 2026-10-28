#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MACOS="$ROOT/macos"
CONFIGURATION=${PAIRDESK_CONFIGURATION:-release}
OUTPUT=${PAIRDESK_APP_OUTPUT:-"$ROOT/dist/PairDesk.app"}
STAGING="$ROOT/dist/.PairDesk.app.staging.$$"
SIGNING_IDENTITY=${DEVELOPER_SIGNING_IDENTITY:-}
LOCAL_SIGNING_IDENTITY="PairDesk Local Signing"
SIGNING_KEYCHAIN=${PAIRDESK_SIGNING_KEYCHAIN:-"$HOME/Library/Keychains/login.keychain-db"}
WHISPER_RUNTIME="$ROOT/.cache/whisper/runtime"
BUILD_PATH=${PAIRDESK_BUILD_PATH:-"$MACOS/.build"}
BUILD_ARCHS="arm64 x86_64"
UNIVERSAL_BIN="$ROOT/dist/.PairDesk-universal-bin.$$"
MODEL_SHA1="bd577a113a864445d4c299885e0cb97d4ba92b5f"

fail() {
  echo "build-app: $*" >&2
  exit 1
}

# Prefer a stable identity: macOS ties keychain and privacy approvals to the
# signature, and an ad-hoc signature changes with every build. The local
# self-signed identity appears in the matching list even when macOS does not
# trust its certificate chain for Gatekeeper. Set
# DEVELOPER_SIGNING_IDENTITY=- to force ad-hoc signing.
if [ -z "$SIGNING_IDENTITY" ]; then
  AVAILABLE_IDENTITIES=$(security find-identity -p codesigning "$SIGNING_KEYCHAIN" 2>/dev/null | sed -n 's/.*"\(.*\)".*/\1/p')
  if printf '%s\n' "$AVAILABLE_IDENTITIES" | grep -Fx "$LOCAL_SIGNING_IDENTITY" >/dev/null; then
    SIGNING_IDENTITY=$LOCAL_SIGNING_IDENTITY
  elif printf '%s\n' "$AVAILABLE_IDENTITIES" | grep -F 'PairDesk Local Signing ' >/dev/null; then
    SIGNING_IDENTITY=$(printf '%s\n' "$AVAILABLE_IDENTITIES" | grep -F 'PairDesk Local Signing ' | head -n 1)
  elif [ "${PAIRDESK_ALLOW_ADHOC:-0}" = "1" ]; then
    SIGNING_IDENTITY=-
    echo "build-app: ad-hoc signing. macOS treats this build as a new app: the saved sign-in asks for the Mac password twice and permissions may need approval again." >&2
  else
    fail "no signing identity. Run 'sh scripts/create-signing-identity.sh' once on this Mac so every build keeps the same identity (otherwise each install asks for the keychain password twice). To build ad-hoc anyway, set PAIRDESK_ALLOW_ADHOC=1."
  fi
fi

if [ "${PAIRDESK_SKIP_BUILD:-0}" = "1" ]; then
  BIN_PATH=${PAIRDESK_BIN_PATH:-$(cd "$MACOS" && swift build --scratch-path "$BUILD_PATH" --show-bin-path -c "$CONFIGURATION")}
  EXECUTABLE="$BIN_PATH/PairDesk"
  BRIDGE_EXECUTABLE="$BIN_PATH/pairdesk-agent-mcp"
  FRAMEWORKS_SOURCE="$BUILD_PATH/artifacts"
  CHECKOUTS="$BUILD_PATH/checkouts"
else
  ARM_BIN_PATH=
  X86_BIN_PATH=
  for arch in $BUILD_ARCHS; do
    case "$arch" in arm64|x86_64) ;; *) fail "unsupported build architecture: $arch" ;; esac
    arch_build_path="$BUILD_PATH/$arch"
    (cd "$MACOS" && swift build --triple "$arch-apple-macosx14.0" --scratch-path "$arch_build_path" -c "$CONFIGURATION")
    arch_bin_path=$(cd "$MACOS" && swift build --triple "$arch-apple-macosx14.0" --scratch-path "$arch_build_path" --show-bin-path -c "$CONFIGURATION")
    case "$arch" in
      arm64) ARM_BIN_PATH=$arch_bin_path ;;
      x86_64) X86_BIN_PATH=$arch_bin_path ;;
    esac
  done
  mkdir -p "$UNIVERSAL_BIN"
  lipo -create "$ARM_BIN_PATH/PairDesk" "$X86_BIN_PATH/PairDesk" -output "$UNIVERSAL_BIN/PairDesk"
  lipo -create "$ARM_BIN_PATH/pairdesk-agent-mcp" "$X86_BIN_PATH/pairdesk-agent-mcp" -output "$UNIVERSAL_BIN/pairdesk-agent-mcp"
  BIN_PATH=$ARM_BIN_PATH
  EXECUTABLE="$UNIVERSAL_BIN/PairDesk"
  BRIDGE_EXECUTABLE="$UNIVERSAL_BIN/pairdesk-agent-mcp"
  FRAMEWORKS_SOURCE="$BUILD_PATH/arm64/artifacts"
  CHECKOUTS="$BUILD_PATH/arm64/checkouts"
fi
test -x "$EXECUTABLE" || fail "SwiftPM executable is missing at $EXECUTABLE"
test -x "$BRIDGE_EXECUTABLE" || fail "SwiftPM MCP helper is missing at $BRIDGE_EXECUTABLE"

test -x "$WHISPER_RUNTIME/whisper-cli" || fail "run scripts/prepare-whisper.sh first"
test -f "$WHISPER_RUNTIME/ggml-tiny.bin" || fail "Whisper Tiny model is missing"
ACTUAL_MODEL_SHA1=$(shasum -a 1 "$WHISPER_RUNTIME/ggml-tiny.bin" | awk '{print $1}')
test "$ACTUAL_MODEL_SHA1" = "$MODEL_SHA1" || fail "Whisper Tiny model checksum mismatch"

mkdir -p "$ROOT/dist"
mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Frameworks" "$STAGING/Contents/Resources/whisper" "$STAGING/Contents/Resources/ThirdPartyNotices"
cleanup() {
  if [ -d "$STAGING" ]; then rm -rf "$STAGING"; fi
  if [ -d "$UNIVERSAL_BIN" ]; then rm -rf "$UNIVERSAL_BIN"; fi
  if [ -n "${BACKUP:-}" ] && [ -e "$BACKUP" ] && [ ! -e "$OUTPUT" ]; then mv "$BACKUP" "$OUTPUT"; fi
}
trap cleanup EXIT HUP INT TERM

CONTENTS="$STAGING/Contents"
FRAMEWORKS="$CONTENTS/Frameworks"
RESOURCES="$CONTENTS/Resources"
APP_EXECUTABLE="$CONTENTS/MacOS/PairDesk"
ditto "$EXECUTABLE" "$APP_EXECUTABLE"
ditto "$BRIDGE_EXECUTABLE" "$CONTENTS/MacOS/pairdesk-agent-mcp"
ditto "$MACOS/Info.plist" "$CONTENTS/Info.plist"
if [ -n "${PAIRDESK_DEFAULT_SERVER:-}" ]; then
  python3 - "$CONTENTS/Info.plist" "$PAIRDESK_DEFAULT_SERVER" <<'PYURL'
import plistlib, sys, urllib.parse
url = urllib.parse.urlsplit(sys.argv[2])
if url.scheme != 'https' or not url.hostname or url.username or url.password or url.query or url.fragment or url.path not in ['', '/']:
    raise SystemExit('PAIRDESK_DEFAULT_SERVER must be an HTTPS API origin')
with open(sys.argv[1], 'rb') as stream:
    info = plistlib.load(stream)
info['PairDeskServerURL'] = sys.argv[2]
with open(sys.argv[1], 'wb') as stream:
    plistlib.dump(info, stream)
PYURL
fi
test -f "$MACOS/Resources/PairDesk.icns" || fail "app icon is missing; run: swift scripts/make-app-icon.swift"
ditto "$MACOS/Resources/PairDesk.icns" "$RESOURCES/PairDesk.icns"
ditto "$WHISPER_RUNTIME/whisper-cli" "$RESOURCES/whisper/whisper-cli"
ditto "$WHISPER_RUNTIME/ggml-tiny.bin" "$RESOURCES/whisper/ggml-tiny.bin"
chmod 755 "$APP_EXECUTABLE" "$CONTENTS/MacOS/pairdesk-agent-mcp" "$RESOURCES/whisper/whisper-cli"

# SwiftPM resource bundles carry Package.resolved resources such as LiveKit's
# privacy manifest. Copy every top-level bundle emitted with the executable.
find "$BIN_PATH" -maxdepth 1 -type d -name '*.bundle' -print | while IFS= read -r bundle; do
  ditto "$bundle" "$RESOURCES/$(basename "$bundle")"
done

# Resolve the app's @rpath-linked SDK frameworks from SwiftPM's built products
# or the selected macOS XCFramework slices. Fail closed on unknown dependencies.
otool -L "$EXECUTABLE" | awk '/compatibility version/ { print $1 }' | sort -u | while IFS= read -r dependency; do
  case "$dependency" in
    /System/*|/usr/lib/*|@loader_path/*|@executable_path/*) continue ;;
    @rpath/*) ;;
    *) fail "unhandled linked dependency: $dependency" ;;
  esac

  relative=${dependency#@rpath/}
  component=${relative%%/*}
  destination="$FRAMEWORKS/$component"
  if [ -e "$destination" ]; then continue; fi

  source=""
  if [ -e "$BIN_PATH/$component" ]; then
    source="$BIN_PATH/$component"
  elif [ -e "$BIN_PATH/PackageFrameworks/$component" ]; then
    source="$BIN_PATH/PackageFrameworks/$component"
  elif [ -d "$FRAMEWORKS_SOURCE" ]; then
    source=$(find "$FRAMEWORKS_SOURCE" -type d -name "$component" -path '*/macos-*/*' -print -quit)
    if [ -z "$source" ]; then source=$(find "$FRAMEWORKS_SOURCE" -type f -name "$component" -print -quit); fi
  fi
  [ -n "$source" ] && [ -e "$source" ] || fail "could not locate linked dependency $component"
  ditto "$source" "$destination"
done

# SwiftPM binaries refer to developer toolchain Swift libraries. Embed the
# platform Swift runtime that the binary actually needs for a standalone app.
xcrun swift-stdlib-tool --copy --platform macosx --destination "$FRAMEWORKS" --scan-executable "$APP_EXECUTABLE"
xcrun swift-stdlib-tool --copy --platform macosx --destination "$FRAMEWORKS" --scan-executable "$CONTENTS/MacOS/pairdesk-agent-mcp"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP_EXECUTABLE"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$CONTENTS/MacOS/pairdesk-agent-mcp"
for bundled_executable in "$APP_EXECUTABLE" "$CONTENTS/MacOS/pairdesk-agent-mcp"; do
  otool -l "$bundled_executable" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }' | sort -u | while IFS= read -r build_rpath; do
    case "$build_rpath" in
      "$BIN_PATH/PackageFrameworks"|*/Xcode.app/Contents/Developer/Toolchains/*)
        install_name_tool -delete_rpath "$build_rpath" "$bundled_executable"
        ;;
    esac
  done
  if otool -l "$bundled_executable" | grep -E '/(Xcode\.app|\.build)/' >/dev/null; then
    fail "build or toolchain rpath remained in $(basename "$bundled_executable")"
  fi
done

NOTICES="$RESOURCES/ThirdPartyNotices"
copy_notice() {
  source=$1
  target=$2
  test -f "$source" || fail "missing third-party notice: $source"
  ditto "$source" "$NOTICES/$target"
}
copy_notice "$ROOT/vendor/livekit-client-swift/LICENSE" "LiveKit-Client-LICENSE.txt"
copy_notice "$ROOT/vendor/livekit-client-swift/NOTICE" "LiveKit-Client-NOTICE.txt"
copy_notice "$CHECKOUTS/webrtc-xcframework/LICENSE" "LiveKit-WebRTC-LICENSE.txt"
copy_notice "$CHECKOUTS/livekit-uniffi-xcframework/LICENSE" "LiveKit-UniFFI-LICENSE.txt"
copy_notice "$ROOT/.cache/whisper/source/LICENSE" "whisper.cpp-LICENSE.txt"
copy_notice "$MACOS/Resources/ThirdPartyNotices/OpenAI-Whisper-LICENSE.txt" "OpenAI-Whisper-LICENSE.txt"
copy_notice "$ROOT/THIRD_PARTY_NOTICES.md" "THIRD_PARTY_NOTICES.md"

plutil -lint "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$CONTENTS/Info.plist" | grep -Fx 'app.internal.pairdesk' >/dev/null
/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$CONTENTS/Info.plist" | grep -Fx '14.0' >/dev/null
/usr/libexec/PlistBuddy -c 'Print :LSMultipleInstancesProhibited' "$CONTENTS/Info.plist" | grep -Fx 'true' >/dev/null || fail "Launch Services must prevent duplicate PairDesk processes"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$CONTENTS/Info.plist" | grep -Fx 'PairDesk' >/dev/null
/usr/libexec/PlistBuddy -c 'Print :NSCameraUsageDescription' "$CONTENTS/Info.plist" | grep -F 'turn on video during a call' >/dev/null || fail "camera usage description is missing or unclear"
ARCHS=$(lipo -archs "$APP_EXECUTABLE")
for arch in $BUILD_ARCHS; do
  lipo "$APP_EXECUTABLE" -verify_arch "$arch" || fail "PairDesk is missing $arch"
  lipo "$CONTENTS/MacOS/pairdesk-agent-mcp" -verify_arch "$arch" || fail "pairdesk-agent-mcp is missing $arch"
  lipo "$RESOURCES/whisper/whisper-cli" -verify_arch "$arch" || fail "Whisper runtime is missing $arch"
done
for framework in "$FRAMEWORKS"/*.framework; do
  [ -d "$framework" ] || continue
  framework_binary="$framework/$(basename "$framework" .framework)"
  for arch in $ARCHS; do
    lipo "$framework_binary" -verify_arch "$arch" || fail "$(basename "$framework") is missing $arch"
  done
done

# The frameworks are individually signed before the app seals the whole bundle.
for framework in "$FRAMEWORKS"/*.framework; do
  [ -d "$framework" ] || continue
  codesign --force --deep --sign "$SIGNING_IDENTITY" "$framework"
done
find "$FRAMEWORKS" -maxdepth 1 -type f -name '*.dylib' -print | while IFS= read -r library; do
  codesign --force --sign "$SIGNING_IDENTITY" "$library"
done
codesign --force --sign "$SIGNING_IDENTITY" "$RESOURCES/whisper/whisper-cli"
codesign --force --sign "$SIGNING_IDENTITY" "$CONTENTS/MacOS/pairdesk-agent-mcp"
codesign --force --deep --sign "$SIGNING_IDENTITY" "$STAGING"
codesign --verify --deep --strict --verbose=2 "$STAGING"

# Publish only after validation/signing. Replace the prior build in place so
# local packaging does not require manually deleting the previous app bundle.
mkdir -p "$(dirname "$OUTPUT")"
if [ -e "$OUTPUT" ]; then
  BACKUP="$OUTPUT.previous.$$"
  mv "$OUTPUT" "$BACKUP"
  if mv "$STAGING" "$OUTPUT"; then
    rm -rf "$BACKUP"
    BACKUP=""
  else
    mv "$BACKUP" "$OUTPUT"
    BACKUP=""
    fail "could not replace the existing app bundle"
  fi
else
  mv "$STAGING" "$OUTPUT"
fi
trap - EXIT HUP INT TERM
echo "Packaged $OUTPUT ($CONFIGURATION, $ARCHS); signing identity: $SIGNING_IDENTITY"
