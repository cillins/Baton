#!/usr/bin/env bash
set -euo pipefail

PROBE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE_OUTPUT_DIR="$(mktemp -d)"
trap 'rm -rf "$PROBE_OUTPUT_DIR"' EXIT

SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
xcrun swiftc \
    -sdk "$SDK_PATH" \
    "$PROBE_ROOT/RemoteTouchSurface.swift" \
    "$PROBE_ROOT/Tests/TouchSurfaceProbe.swift" \
    -import-objc-header "$PROBE_ROOT/SiriRemote-Bridging-Header.h" \
    -Xlinker -F -Xlinker /System/Library/PrivateFrameworks \
    -framework IOKit \
    -framework MultitouchSupport \
    -o "$PROBE_OUTPUT_DIR/TouchSurfaceProbe"

"$PROBE_OUTPUT_DIR/TouchSurfaceProbe"
