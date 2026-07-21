#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_OUTPUT_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_OUTPUT_DIR"' EXIT

xcrun swiftc \
    "$TEST_ROOT/RemoteTouchSurface.swift" \
    "$TEST_ROOT/Tests/RemoteTouchSurfaceTests.swift" \
    -o "$TEST_OUTPUT_DIR/RemoteTouchSurfaceTests"

"$TEST_OUTPUT_DIR/RemoteTouchSurfaceTests"
