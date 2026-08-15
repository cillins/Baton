#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
DRIVER_DIR="$BUILD_DIR/BatonRemoteMicrophone.driver"
CONTENTS_DIR="$DRIVER_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources/en.lproj"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
TARGET_ARCH="$(uname -m)"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

clang \
    -isysroot "$SDK_PATH" \
    -arch "$TARGET_ARCH" \
    -mmacosx-version-min=12.0 \
    -std=gnu11 \
    -fblocks \
    -O2 \
    -bundle \
    -framework CoreAudio \
    -framework CoreFoundation \
    "$SCRIPT_DIR/BatonRemoteMicrophone.c" \
    -o "$MACOS_DIR/BatonRemoteMicrophone"

cp "$SCRIPT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$SCRIPT_DIR/en.lproj/Localizable.strings" "$RESOURCES_DIR/Localizable.strings"

SIGN_IDENTITY="${BATON_SIGN_IDENTITY:--}"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$DRIVER_DIR"

echo "$DRIVER_DIR"
