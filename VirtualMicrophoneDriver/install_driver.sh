#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DRIVER_DIR="$SCRIPT_DIR/build/BatonRemoteMicrophone.driver"
INSTALL_DIR="/Library/Audio/Plug-Ins/HAL"
INSTALL_PATH="$INSTALL_DIR/BatonRemoteMicrophone.driver"

if [ ! -d "$DRIVER_DIR" ]; then
    "$SCRIPT_DIR/build_driver.sh"
fi

sudo mkdir -p "$INSTALL_DIR"
sudo ditto "$DRIVER_DIR" "$INSTALL_PATH"
sudo chown -R root:wheel "$INSTALL_PATH"
sudo killall coreaudiod 2>/dev/null || true

echo "Installed Baton Remote Microphone. It should now appear in Audio MIDI Setup."
