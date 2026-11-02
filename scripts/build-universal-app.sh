#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MACOS="$ROOT/macos"
CONFIGURATION=${PAIRDESK_CONFIGURATION:-release}
BUILD_ROOT=${PAIRDESK_UNIVERSAL_BUILD_ROOT:-"$ROOT/.cache/build-universal-app"}
ARM_BUILD_PATH=${PAIRDESK_ARM_BUILD_PATH:-"$BUILD_ROOT/arm64"}
INTEL_BUILD_PATH=${PAIRDESK_INTEL_BUILD_PATH:-"$BUILD_ROOT/x86_64"}
ARM_TRIPLE=${PAIRDESK_ARM_TRIPLE:-arm64-apple-macosx14.0}
INTEL_TRIPLE=${PAIRDESK_INTEL_TRIPLE:-x86_64-apple-macosx14.0}

mkdir -p "$ROOT/.cache"
UNIVERSAL_BIN=$(mktemp -d "$ROOT/.cache/pairdesk-universal-bin.XXXXXX")
cleanup() { rm -rf "$UNIVERSAL_BIN"; }
trap cleanup EXIT HUP INT TERM

build_path() {
  scratch=$1
  triple=$2
  echo "Building PairDesk for $triple ($CONFIGURATION)"
  (cd "$MACOS" && swift build --scratch-path "$scratch" --triple "$triple" -c "$CONFIGURATION")
}

bin_path() {
  scratch=$1
  triple=$2
  (cd "$MACOS" && swift build --scratch-path "$scratch" --triple "$triple" --show-bin-path -c "$CONFIGURATION")
}

build_path "$ARM_BUILD_PATH" "$ARM_TRIPLE"
build_path "$INTEL_BUILD_PATH" "$INTEL_TRIPLE"
ARM_BIN=$(bin_path "$ARM_BUILD_PATH" "$ARM_TRIPLE")
INTEL_BIN=$(bin_path "$INTEL_BUILD_PATH" "$INTEL_TRIPLE")

for product in PairDesk pairdesk-agent-mcp; do
  test -x "$ARM_BIN/$product" || { echo "Missing arm64 product: $ARM_BIN/$product" >&2; exit 1; }
  test -x "$INTEL_BIN/$product" || { echo "Missing x86_64 product: $INTEL_BIN/$product" >&2; exit 1; }
  lipo -create "$ARM_BIN/$product" "$INTEL_BIN/$product" -output "$UNIVERSAL_BIN/$product"
  lipo -verify_arch arm64 "$UNIVERSAL_BIN/$product"
  lipo -verify_arch x86_64 "$UNIVERSAL_BIN/$product"
done

if [ "${PAIRDESK_BUILD_ONLY:-0}" = "1" ]; then
  echo "Verified universal macOS executables (arm64 + x86_64); app packaging was skipped."
  exit 0
fi

# Carry SwiftPM resource bundles and universal XCFrameworks from the arm build.
# build-app.sh validates that every framework linked by the merged executables
# also contains both architectures before signing the app bundle.
find "$ARM_BIN" -maxdepth 1 -type d -name '*.bundle' -print | while IFS= read -r bundle; do
  ditto "$bundle" "$UNIVERSAL_BIN/$(basename "$bundle")"
done

PAIRDESK_CONFIGURATION="$CONFIGURATION" \
PAIRDESK_SKIP_BUILD=1 \
PAIRDESK_BUILD_PATH="$ARM_BUILD_PATH" \
PAIRDESK_BIN_PATH="$UNIVERSAL_BIN" \
sh "$ROOT/scripts/build-app.sh"
