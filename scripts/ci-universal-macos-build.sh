#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MACOS="$ROOT/macos"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/pairwise-universal-build.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT HUP INT TERM

for arch in arm64 x86_64; do
  target="$arch-apple-macosx14.0"
  scratch_path="$SCRATCH/$arch"
  (cd "$MACOS" && swift build --triple "$target" --scratch-path "$scratch_path" -c release)
  bin_path=$(cd "$MACOS" && swift build --triple "$target" --scratch-path "$scratch_path" --show-bin-path -c release)

  for executable in PairDesk pairdesk-agent-mcp; do
    lipo "$bin_path/$executable" -verify_arch "$arch"
  done
  for framework in "$bin_path"/*.framework; do
    [ -d "$framework" ] || continue
    binary="$framework/$(basename "$framework" .framework)"
    lipo "$binary" -verify_arch "$arch"
  done
done
