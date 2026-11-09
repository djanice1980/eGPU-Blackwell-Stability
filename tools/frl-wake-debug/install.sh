#!/usr/bin/env bash
# Turn on drm debug logging (drm.debug=0x6: driver + KMS) on every boot, and raise the journal
# cap so a day of it fits, to see why a wake on 7.3.3 can leave the HDMI picture off.
#
# Why (2026-11-09 12:39): at a wake the kernel re-detected the TV mid-recovery; detection runs a
# destructive FRL capability test at the sink's maximum (rate 6, 12G x4) that switches the
# streams off, and nothing switched them back on: the link sat at rate 6 with no picture and the
# watchdog's 13 re-enables never trained. At warning level the log cannot say whether amdgpu sent
# a hotplug event, whether a restore commit ran, or what the test itself did. 0x2 (driver) shows
# the DC detection and training steps, 0x4 (KMS) the hotplug events and commits.
#
# Cost: the patched watchdog logs every 200 ms poll at 0x2 (~5 lines/s while the TV is on), far
# more than the stock 50M journal cap (cachyos-settings) holds, so the cap goes to 3G here.
#   sudo bash install.sh      then reboot, or nothing: it also switches debug on now
#   sudo bash uninstall.sh    when the capture is done (only after the logs have been read --
#                             the 50M cap returns and journald trims the rest)
set -eu
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

install -d /etc/systemd/journald.conf.d
printf '%s\n' "# frl-wake-debug: room for drm.debug=0x6 (eGPU-Blackwell-Stability tools/frl-wake-debug)" \
    "[Journal]" "SystemMaxUse=3G" > /etc/systemd/journald.conf.d/zz-frl-wake-debug.conf

printf '%s\n' "[Unit]" \
    "Description=drm debug 0x6 for the HDMI FRL wake capture (eGPU-Blackwell-Stability)" \
    "" "[Service]" "Type=oneshot" "RemainAfterExit=yes" \
    "ExecStart=/bin/sh -c 'echo 0x6 > /sys/module/drm/parameters/debug'" \
    "ExecStop=/bin/sh -c 'echo 0 > /sys/module/drm/parameters/debug'" \
    "" "[Install]" "WantedBy=multi-user.target" > /etc/systemd/system/frl-wake-debug.service

systemctl restart systemd-journald
systemctl daemon-reload
systemctl enable --now frl-wake-debug.service
echo "drm debug now: $(cat /sys/module/drm/parameters/debug)"
journalctl --disk-usage
