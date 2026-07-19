#!/bin/bash

# Builds BleProbe.app — a standalone GATT research tool (Phase 0).
# Packaged as a bundle so macOS TCC shows a proper Bluetooth permission prompt;
# bare CLI binaries never trigger the prompt and the central state callback stalls.

set -e

echo "Building BleProbe..."

SDK_PATH=$(xcrun --show-sdk-path --sdk macosx 2>/dev/null || echo "")
if [ -z "$SDK_PATH" ]; then
    echo "Error: macOS SDK not found. Install Xcode Command Line Tools: xcode-select --install"
    exit 1
fi

ARCH=$(uname -m)
if [ "$ARCH" == "arm64" ]; then
    TARGET="arm64-apple-macosx11.0"
else
    TARGET="x86_64-apple-macosx11.0"
fi

swiftc \
    -sdk "$SDK_PATH" \
    -target "$TARGET" \
    -o BleProbe \
    ble_probe.swift \
    -framework CoreBluetooth

APP_BUNDLE="BleProbe.app"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
cp BleProbe "${APP_BUNDLE}/Contents/MacOS/BleProbe"

cat > "${APP_BUNDLE}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>BleProbe</string>
	<key>CFBundleIdentifier</key>
	<string>com.baton.bleprobe</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>BleProbe</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleVersion</key>
	<string>1.0</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>LSMinimumSystemVersion</key>
	<string>11.0</string>
	<key>NSBluetoothAlwaysUsageDescription</key>
	<string>BleProbe 需要蓝牙权限来枚举 Siri Remote 的 GATT 服务。</string>
	<key>NSBluetoothPeripheralUsageDescription</key>
	<string>BleProbe 需要蓝牙权限来枚举 Siri Remote 的 GATT 服务。</string>
</dict>
</plist>
EOF

chmod +x "${APP_BUNDLE}/Contents/MacOS/BleProbe"

if [ -f "Baton.entitlements" ]; then
    codesign --force --options=runtime \
        --entitlements "Baton.entitlements" \
        --sign - \
        "${APP_BUNDLE}"
fi

echo "✓ Created ${APP_BUNDLE}"
echo ""
echo "Run from terminal (stdout stays in terminal, TCC attributes to the bundle):"
echo "  ${APP_BUNDLE}/Contents/MacOS/BleProbe 75"
