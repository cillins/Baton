#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Baton"
APP_BUNDLE="${APP_NAME}.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_BUNDLE}/Contents/Info.plist")"
ARCH="$(uname -m)"
OUTPUT_DIR="dist"
OUTPUT_DMG="${OUTPUT_DIR}/${APP_NAME}-${VERSION}-${ARCH}.dmg"
VOLUME_NAME="${APP_NAME} ${VERSION}"
BLUETOOTH_PROFILE="${BATON_BLUETOOTH_PROFILE:-}"

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "Error: ${APP_BUNDLE} not found. Run ./create_app_bundle.sh first." >&2
    exit 1
fi

STAGING_DIR="$(mktemp -d /tmp/baton-dmg.XXXXXX)"
cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

mkdir -p "$OUTPUT_DIR"
ditto "$APP_BUNDLE" "${STAGING_DIR}/${APP_BUNDLE}"
ln -s /Applications "${STAGING_DIR}/Applications"

if [[ -n "$BLUETOOTH_PROFILE" ]]; then
    if [[ ! -f "$BLUETOOTH_PROFILE" ]]; then
        echo "Error: Bluetooth logging profile not found: ${BLUETOOTH_PROFILE}" >&2
        exit 1
    fi
    PROFILE_NAME="$(security cms -D -i "$BLUETOOTH_PROFILE" \
        | plutil -extract PayloadDisplayName raw -o - -)"
    PROFILE_SCOPE="$(security cms -D -i "$BLUETOOTH_PROFILE" \
        | plutil -extract PayloadScope raw -o - -)"
    if [[ "$PROFILE_NAME" != "Bluetooth Logging for macOS" \
        || "$PROFILE_SCOPE" != "system" ]]; then
        echo "Error: selected profile is not Bluetooth Logging for macOS." >&2
        exit 1
    fi
    ditto "$BLUETOOTH_PROFILE" \
        "${STAGING_DIR}/Bluetooth Logging for macOS.mobileconfig"
fi

rm -f "$OUTPUT_DMG"
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "$OUTPUT_DMG"

echo "✓ DMG created: ${OUTPUT_DMG}"
