#!/bin/bash

set -euo pipefail

DESTINATION="/Library/Audio/Plug-Ins/HAL/BatonRemoteMicrophone.driver"
echo "正在移除 Baton Remote Microphone，需要管理员密码。"
sudo rm -rf "$DESTINATION"
sudo killall coreaudiod 2>/dev/null || true
echo "已移除。"
read -r -p "按回车关闭…"
