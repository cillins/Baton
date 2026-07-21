#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Baton"
BUNDLE_ID="com.baton.app"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$PROJECT_ROOT/Baton.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/Baton"

cd "$PROJECT_ROOT"
pkill -x "$APP_NAME" >/dev/null 2>&1 || true

./build.sh
./create_app_bundle.sh

open_app() {
    /usr/bin/open -na "$APP_BUNDLE"
}

case "$MODE" in
    run)
        open_app
        ;;
    --debug|debug)
        lldb -- "$APP_BINARY"
        ;;
    --logs|logs)
        open_app
        /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
        ;;
    --telemetry|telemetry)
        open_app
        /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
        ;;
    --verify|verify)
        open_app
        sleep 2
        pgrep -x "$APP_NAME" >/dev/null
        ;;
    *)
        echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
        exit 2
        ;;
esac
