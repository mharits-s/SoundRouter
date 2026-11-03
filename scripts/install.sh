#!/bin/sh
# usage (root): install.sh <names.txt> <SoundRouter.driver>
# Installs the driver + device-name list, then restarts coreaudiod (audio drops for ~1s).
set -e
D="/Library/Application Support/SoundRouter"
mkdir -p "$D"; chmod 777 "$D"
cp "$1" "$D/devices.txt"; chmod 666 "$D/devices.txt"
H=/Library/Audio/Plug-Ins/HAL
mkdir -p "$H"; rm -rf "$H/SoundRouter.driver"
cp -R "$2" "$H/SoundRouter.driver"; chown -R root:wheel "$H/SoundRouter.driver"
killall coreaudiod || true
