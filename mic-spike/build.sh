#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ -n "${OPUS_PREFIX:-}" ]]; then
    OPUS_ROOT="$OPUS_PREFIX"
elif command -v brew >/dev/null 2>&1; then
    OPUS_ROOT="$(brew --prefix opus)"
else
    echo "error: libopus not found; install it with 'brew install opus' or set OPUS_PREFIX" >&2
    exit 1
fi

xcrun swiftc \
    "$SCRIPT_DIR/main.swift" \
    -import-objc-header "$SCRIPT_DIR/opus-bridge.h" \
    -I "$OPUS_ROOT/include" \
    -L "$OPUS_ROOT/lib" \
    -lopus \
    -o "$SCRIPT_DIR/mic-spike"

echo "Built $SCRIPT_DIR/mic-spike"
