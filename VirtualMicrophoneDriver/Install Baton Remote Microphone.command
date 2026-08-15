#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$SCRIPT_DIR/BatonRemoteMicrophone.driver"
DESTINATION="/Library/Audio/Plug-Ins/HAL/BatonRemoteMicrophone.driver"

if [ ! -d "$SOURCE" ]; then
    echo "找不到 BatonRemoteMicrophone.driver。请从 Baton.app 内运行安装。"
    read -r -p "按回车关闭…"
    exit 1
fi

echo "正在安装 Baton Remote Microphone，需要管理员密码。"
sudo mkdir -p "/Library/Audio/Plug-Ins/HAL"
sudo rm -rf "$DESTINATION"
sudo ditto "$SOURCE" "$DESTINATION"
sudo chown -R root:wheel "$DESTINATION"
sudo killall coreaudiod 2>/dev/null || true

echo "安装完成。Baton Remote Microphone 现在应出现在声音输入设备列表中。"
read -r -p "按回车关闭…"
