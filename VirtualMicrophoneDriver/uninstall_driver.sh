#!/bin/bash

set -euo pipefail

INSTALL_PATH="/Library/Audio/Plug-Ins/HAL/BatonRemoteMicrophone.driver"

if [ -d "$INSTALL_PATH" ]; then
    sudo rm -rf "$INSTALL_PATH"
    sudo killall coreaudiod 2>/dev/null || true
fi

echo "Removed Baton Remote Microphone."
