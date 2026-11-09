#!/usr/bin/env bash
# Undo install.sh: drm debug off, the 50M journal cap from cachyos-settings back in force.
# Removes only the two files install.sh wrote. Run only after the capture has been read:
# journald trims the journal back to 50M on its next rotation.
set -eu
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
systemctl disable --now frl-wake-debug.service 2>/dev/null || true
echo 0 > /sys/module/drm/parameters/debug
rm -f /etc/systemd/system/frl-wake-debug.service /etc/systemd/journald.conf.d/zz-frl-wake-debug.conf
rmdir /etc/systemd/journald.conf.d 2>/dev/null || true   # only if now empty
systemctl daemon-reload
systemctl restart systemd-journald
echo "drm debug now: $(cat /sys/module/drm/parameters/debug)"
