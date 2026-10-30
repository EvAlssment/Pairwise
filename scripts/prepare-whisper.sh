#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CACHE="$ROOT/.cache/whisper"
SOURCE="$CACHE/source"
BUILD="$CACHE/build-universal"
OUTPUT="$CACHE/runtime"
TOOLING="$ROOT/.cache/tooling"
REPO="https://github.com/ggml-org/whisper.cpp.git"
REVISION="a8d002cfd879315632a579e73f0148d06959de36" # v1.7.6
MODEL_SHA1="bd577a113a864445d4c299885e0cb97d4ba92b5f"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin"

mkdir -p "$CACHE" "$TOOLING" "$OUTPUT"

if command -v cmake >/dev/null 2>&1; then
  CMAKE=$(command -v cmake)
elif [ -x "$TOOLING/python/cmake/data/bin/cmake" ]; then
  CMAKE="$TOOLING/python/cmake/data/bin/cmake"
else
  PYTHON=${PAIRDESK_PYTHON:-python3}
  "$PYTHON" -m pip install --disable-pip-version-check --timeout 120 --retries 5 --target "$TOOLING/python" cmake==4.1.2
  CMAKE="$TOOLING/python/cmake/data/bin/cmake"
fi

if [ ! -d "$SOURCE/.git" ]; then
  git init "$SOURCE"
  git -C "$SOURCE" remote add origin "$REPO"
fi
git -C "$SOURCE" fetch --depth 1 origin "$REVISION"
git -C "$SOURCE" checkout --detach FETCH_HEAD

MODEL="$CACHE/ggml-tiny.bin"
if [ ! -f "$MODEL" ] || [ "$(shasum -a 1 "$MODEL" | awk '{print $1}')" != "$MODEL_SHA1" ]; then
  curl --fail --location --retry 3 "$MODEL_URL" --output "$MODEL.tmp"
  ACTUAL=$(shasum -a 1 "$MODEL.tmp" | awk '{print $1}')
  if [ "$ACTUAL" != "$MODEL_SHA1" ]; then
    rm -f "$MODEL.tmp"
    echo "Whisper Tiny checksum mismatch: expected $MODEL_SHA1, got $ACTUAL" >&2
    exit 1
  fi
  mv "$MODEL.tmp" "$MODEL"
fi

"$CMAKE" -S "$SOURCE" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release -DWHISPER_BUILD_TESTS=OFF -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 "-DCMAKE_OSX_ARCHITECTURES=arm64;x86_64"
"$CMAKE" --build "$BUILD" --config Release --target whisper-cli --parallel 2
install -m 755 "$BUILD/bin/whisper-cli" "$OUTPUT/whisper-cli"
install -m 644 "$MODEL" "$OUTPUT/ggml-tiny.bin"
lipo "$OUTPUT/whisper-cli" -verify_arch arm64
lipo "$OUTPUT/whisper-cli" -verify_arch x86_64
test "$(shasum -a 1 "$OUTPUT/ggml-tiny.bin" | awk '{print $1}')" = "$MODEL_SHA1"
printf 'Ready (universal arm64+x86_64): %s\nModel SHA-1: %s\n' "$OUTPUT" "$MODEL_SHA1"
