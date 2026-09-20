#!/usr/bin/env bash
# Collect evidence WHILE the external display is dark / "No Signal", BEFORE rescuing it.
#
# Why: after an overnight DPMS standby the LG C2 reports No Signal even though the driver
# completes the whole bring-up without error (FRL link training PASSED first try, sink sets
# FRL_START=1 -- captured 2026-09-20). Two DPMS off/on cycles did not recover it; only a
# modeset to a different refresh rate did. So the question this script answers is: with the
# panel dark, what does the source think the link is doing, and is the sink still talking?
#
#   bash hdmi-dark-diag.sh              # writes ~/hdmi-dark-<stamp>.txt
# Run it from the desktop session (kscreen-doctor needs it). Asks for sudo: connector debugfs
# and the DDC/EDID read are root-only. Changes nothing -- rescue afterwards with
# tools/display-rescue.
set -u
OUT="${1:-$HOME/hdmi-dark-$(date +%Y%m%d-%H%M%S).txt}"
exec > >(tee "$OUT") 2>&1
echo "=== hdmi-dark-diag $(date '+%F %T') ==="

echo; echo "--- kernel/module ---"
uname -r; modinfo -n amdgpu; cat /proc/cmdline

echo; echo "--- connector state (does the sink still answer DDC?) ---"
for c in /sys/class/drm/card*-HDMI-A-*; do
    [ -e "$c/status" ] || continue
    printf '%s status=%s enabled=%s dpms=%s edid_bytes=%s\n' "$(basename "$c")" \
        "$(cat "$c/status")" "$(cat "$c/enabled" 2>/dev/null)" "$(cat "$c/dpms" 2>/dev/null)" \
        "$(wc -c < "$c/edid" 2>/dev/null)"
done
echo "(edid_bytes 256/512 = the sink is still answering; 0 = the link is gone)"

echo; echo "--- what the compositor thinks is set ---"
kscreen-doctor -o 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | sed -n '/HDMI-A-1/,/^Output: [0-9]* eDP/p' \
    | grep -E "Output:|enabled|connected|Vrr|HDR|Wide|^\s+[0-9]+:.*\*" | head

echo; echo "--- is a picture actually being scanned out? (bpc/colorspace come from live HW) ---"
sudo sh -c 'for d in /sys/kernel/debug/dri/*/crtc-*; do
    [ -e "$d/amdgpu_current_bpc" ] || continue
    echo "$d bpc=$(cat "$d/amdgpu_current_bpc" 2>/dev/null) colorspace=$(cat "$d/amdgpu_current_colorspace" 2>/dev/null)"
done'

echo; echo "--- amdgpu connector debugfs (the HDMI connector is a native FRL link) ---"
sudo sh -c 'for d in /sys/kernel/debug/dri/*/HDMI-A-1 /sys/kernel/debug/dri/*/DP-*; do
    [ -d "$d" ] || continue
    echo "[$d]"; ls "$d"
    for f in link_settings dp_dpcd_data output_bpc internal_display; do
        [ -r "$d/$f" ] && { echo "  $f:"; head -c 400 "$d/$f" | sed "s/^/    /"; echo; }
    done
done'

echo; echo "--- last 60 kernel lines mentioning the display path ---"
journalctl -k --no-pager -o short-precise -n 4000 \
    | grep -iE "amdgpu|drm|FRL|hdmi" | tail -60

echo; echo "=== written to $OUT ==="
echo "Next: bash tools/display-rescue   (mode bounce; --hard for disable/enable)"
