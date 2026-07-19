#!/bin/bash

# Build script for Baton
# Make sure Xcode Command Line Tools are installed: xcode-select --install

set -e

echo "Building Baton..."

SWIFT_FILES=(
    "main.swift"
    "SiriRemoteApp.swift"
    "MenuBarManager.swift"
    "RemoteDetector.swift"
    "RemoteInputHandler.swift"
    "CursorController.swift"
    "MediaController.swift"
    "MediaKeyInterceptor.swift"
    "TouchHandler.swift"
    "SystemVolume.swift"
    "AudioProbe.swift"
    "BleAudioProbe.swift"
    "BleBatteryMonitor.swift"
    "SettingsWindowController.swift"
    "MotionProbe.swift"
    "MotionCapture.swift"
)

# Find SDK path
SDK_PATH=$(xcrun --show-sdk-path --sdk macosx 2>/dev/null || echo "")

if [ -z "$SDK_PATH" ]; then
    echo "Error: macOS SDK not found. Please install Xcode Command Line Tools:"
    echo "  xcode-select --install"
    exit 1
fi

echo "Using SDK: $SDK_PATH"

# Detect architecture
ARCH=$(uname -m)
if [ "$ARCH" == "arm64" ]; then
    TARGET="arm64-apple-macosx11.0"
else
    TARGET="x86_64-apple-macosx11.0"
fi

echo "Building for: $TARGET"

# Build
# Note: -F /System/Library/PrivateFrameworks is passed only to the linker via -Xlinker
# because exposing private frameworks to the compiler breaks WebKit's transitive
# Network module build (private Network.framework headers don't match the public module).
# MultitouchSupport's headers are imported via the local SiriRemote-Bridging-Header.h,
# so the compiler doesn't need to see the framework - only the linker does.
swiftc \
    -sdk "$SDK_PATH" \
    -target "$TARGET" \
    -o Baton \
    "${SWIFT_FILES[@]}" \
    -import-objc-header SiriRemote-Bridging-Header.h \
    -Xlinker -F -Xlinker /System/Library/PrivateFrameworks \
    -framework IOKit \
    -framework CoreGraphics \
    -framework AudioToolbox \
    -framework Carbon \
    -framework AppKit \
    -framework WebKit \
    -framework GameController \
    -framework MultitouchSupport

if [ $? -eq 0 ]; then
    echo ""
    echo "✓ Build successful!"
    echo ""
    echo "To create a proper macOS app bundle, run:"
    echo "  ./create_app_bundle.sh"
    echo ""
    echo "Or run directly with:"
    echo "  ./Baton"
else
    echo ""
    echo "✗ Build failed!"
    exit 1
fi
