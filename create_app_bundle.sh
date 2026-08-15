#!/bin/bash

# Creates a proper macOS app bundle structure

set -e

APP_NAME="Baton"
APP_BUNDLE="${APP_NAME}.app"
VERSION="${BATON_VERSION:-1.0.0}"
BUILD_NUMBER="${BATON_BUILD_NUMBER:-1}"

if [ ! -f "$APP_NAME" ]; then
    echo "Error: $APP_NAME executable not found."
    echo "Please build first with: ./build.sh"
    exit 1
fi

BINARY_NAME="$APP_NAME"

echo "Creating app bundle: $APP_BUNDLE"

# Create bundle structure
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
mkdir -p "${APP_BUNDLE}/Contents/Frameworks"
mkdir -p "${APP_BUNDLE}/Contents/Library/HelperTools"
mkdir -p "${APP_BUNDLE}/Contents/Library/LaunchDaemons"

# Copy executable
cp "$BINARY_NAME" "${APP_BUNDLE}/Contents/MacOS/$APP_NAME"

# Bundle the virtual-microphone components. They remain dormant until the
# user explicitly approves the helper and installs the HAL driver.
./build_mic_helper.sh
./VirtualMicrophoneDriver/build_driver.sh
cp "dist/microphone/BatonMicCaptureHelper" \
    "${APP_BUNDLE}/Contents/Library/HelperTools/BatonMicCaptureHelper"
cp "MicCaptureHelper/com.baton.miccapture.plist" \
    "${APP_BUNDLE}/Contents/Library/LaunchDaemons/com.baton.miccapture.plist"
rm -rf "${APP_BUNDLE}/Contents/Resources/BatonRemoteMicrophone.driver"
ditto "VirtualMicrophoneDriver/build/BatonRemoteMicrophone.driver" \
    "${APP_BUNDLE}/Contents/Resources/BatonRemoteMicrophone.driver"
cp "VirtualMicrophoneDriver/LICENSE-APPLE-SAMPLE.txt" \
    "${APP_BUNDLE}/Contents/Resources/VirtualMicrophoneDriver-License.txt"
cp "VirtualMicrophoneDriver/Install Baton Remote Microphone.command" \
    "${APP_BUNDLE}/Contents/Resources/Install Baton Remote Microphone.command"
cp "VirtualMicrophoneDriver/Uninstall Baton Remote Microphone.command" \
    "${APP_BUNDLE}/Contents/Resources/Uninstall Baton Remote Microphone.command"
chmod +x \
    "${APP_BUNDLE}/Contents/Resources/Install Baton Remote Microphone.command" \
    "${APP_BUNDLE}/Contents/Resources/Uninstall Baton Remote Microphone.command"

OPUS_LIBRARY="/opt/homebrew/opt/opus/lib/libopus.0.dylib"
if [ ! -f "$OPUS_LIBRARY" ]; then
    OPUS_LIBRARY="/usr/local/opt/opus/lib/libopus.0.dylib"
fi
if [ -f "$OPUS_LIBRARY" ]; then
    rm -f "${APP_BUNDLE}/Contents/Frameworks/libopus.0.dylib"
    cp "$OPUS_LIBRARY" "${APP_BUNDLE}/Contents/Frameworks/libopus.0.dylib"
else
    echo "Warning: libopus.0.dylib not found; remote microphone decoding will be unavailable."
fi

# Regenerate the app icon from the tracked master so clean checkouts never
# depend on an ignored, stale Baton.icns build artifact.
swift gen_icon.swift
iconutil -c icns Baton.iconset -o Baton.icns

# Copy icon if it exists
if [ -f "Baton.icns" ]; then
    cp "Baton.icns" "${APP_BUNDLE}/Contents/Resources/Baton.icns"
    echo "Icon added to app bundle"
elif [ -f "SiriRemote.icns" ]; then
    cp "SiriRemote.icns" "${APP_BUNDLE}/Contents/Resources/Baton.icns"
    echo "Icon added to app bundle"
fi

# Copy menu bar icon resources
if [ -d "Resources" ]; then
    cp Resources/MenuBarIcon*.png "${APP_BUNDLE}/Contents/Resources/" 2>/dev/null || true
    cp Resources/GitHubMark.svg "${APP_BUNDLE}/Contents/Resources/" 2>/dev/null || true
    cp Resources/Opus-License.txt "${APP_BUNDLE}/Contents/Resources/" 2>/dev/null || true
    echo "Menu bar icons added to app bundle"
fi

# Create proper Info.plist with all required keys
echo "Creating Info.plist..."
cat > "${APP_BUNDLE}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundleIdentifier</key>
	<string>com.baton.app</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_NUMBER</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleIconFile</key>
	<string>Baton</string>
	<key>NSHumanReadableCopyright</key>
	<string>Copyright © 2026 Baton Contributors</string>
	<key>LSMinimumSystemVersion</key>
	<string>12.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSBluetoothAlwaysUsageDescription</key>
	<string>Baton 需要蓝牙权限来连接你的 Siri Remote 触控板。</string>
	<key>NSBluetoothPeripheralUsageDescription</key>
	<string>Baton 需要蓝牙权限来连接你的 Siri Remote 触控板。</string>
</dict>
</plist>
EOF

# Make executable
chmod +x "${APP_BUNDLE}/Contents/MacOS/$APP_NAME"

# Sign with hardened runtime + entitlements. Required on modern macOS (14+) for
# IOHIDManager to deliver Bluetooth HID devices like the Siri Remote to the app.
# Ad-hoc (`--sign -`) remains the default. Set BATON_SIGN_IDENTITY to an
# Apple Development, Developer ID, or self-signed identity to keep the same
# code-signing identity—and therefore TCC grants—across local rebuilds.
SIGN_IDENTITY="${BATON_SIGN_IDENTITY:--}"
if [ -f "Baton.entitlements" ]; then
    echo "Signing with hardened runtime + entitlements (identity: ${SIGN_IDENTITY})..."
    if [ -f "${APP_BUNDLE}/Contents/Frameworks/libopus.0.dylib" ]; then
        codesign --force --options=runtime --timestamp=none \
            --sign "$SIGN_IDENTITY" "${APP_BUNDLE}/Contents/Frameworks/libopus.0.dylib"
    fi
    codesign --force --options=runtime --timestamp=none \
        --identifier com.baton.miccapture \
        --sign "$SIGN_IDENTITY" "${APP_BUNDLE}/Contents/Library/HelperTools/BatonMicCaptureHelper"
    codesign --force --timestamp=none --sign "$SIGN_IDENTITY" \
        "${APP_BUNDLE}/Contents/Resources/BatonRemoteMicrophone.driver"
    codesign --force --options=runtime \
        --entitlements "Baton.entitlements" \
        --sign "$SIGN_IDENTITY" \
        "${APP_BUNDLE}"
    codesign -dvv "${APP_BUNDLE}" 2>&1 | grep -E "(flags|Identifier)" || true
fi

echo ""
echo "✓ App bundle created: $APP_BUNDLE"
echo ""
echo "You can now:"
echo "  1. Double-click $APP_BUNDLE to run it"
echo "  2. Or run: open $APP_BUNDLE"
echo ""
echo "Note: You'll need to grant Accessibility permissions in:"
echo "  System Settings → Privacy & Security → Accessibility"
