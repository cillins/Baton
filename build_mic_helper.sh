#!/bin/bash

set -euo pipefail

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macosx13.0"
OUTPUT_DIR="dist/microphone"
OUTPUT="$OUTPUT_DIR/BatonMicCaptureHelper"

mkdir -p "$OUTPUT_DIR"
swiftc \
    -sdk "$SDK_PATH" \
    -target "$TARGET" \
    RemoteMicrophoneXPC.swift \
    MicCaptureHelper/main.swift \
    -framework Security \
    -o "$OUTPUT"

SIGN_IDENTITY="${BATON_SIGN_IDENTITY:--}"
codesign --force --options=runtime --timestamp=none \
    --identifier com.baton.miccapture \
    --sign "$SIGN_IDENTITY" "$OUTPUT"
echo "$OUTPUT"
