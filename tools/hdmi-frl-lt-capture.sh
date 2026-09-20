#!/usr/bin/env bash
# Capture amdgpu's HDMI FRL link-training log across one DPMS off/on cycle.
#
# Why: on kernel 7.2 the DPMS-on path trains the FRL link at ONE rate (the lowest that fits
# the mode: 4K60 10-bit -> 6G x4, 4K120 10-bit RGB -> 10G x4), up to 4 attempts 200 ms apart,
# and never steps the rate down (link_dpms.c enable_link_hdmi_frl ->
# hdmi_frl_perform_link_training_with_retries). The training messages are drm_dbg() and are
# silent unless the driver debug class is on. This turns it on only for the cycle.
#
# What the result means (from link_hdmi_frl.c):
#   "FAILED - FLT_READY not set by sink"        the TV's receiver was not ready yet (slow wake)
#   "FAILED - Timeout waiting for FLT_UPDATE"    training started but lanes never locked (signal
#                                                quality at that rate: cable / PCON / TV input)
#   "Sink requesting lower link rate"            the TV rejected the rate outright
#   "PASSED"                                     trained; if the screen still stayed dark the
#                                                problem is after link training
#   "Write link rate = N": 1=3G x3, 2=6G x3, 3=6G x4, 4=8G x4, 5=10G x4, 6=12G x4
#
# Run from the desktop session as your user (kscreen-doctor needs the session):
#   bash hdmi-frl-lt-capture.sh              # 20 s off, then on, log to ~/frl-lt-<stamp>.log
#   OFF_SECONDS=60 bash hdmi-frl-lt-capture.sh
# Both screens go dark for OFF_SECONDS. If the external one stays dark afterwards, Meta+Shift+D
# (the display-rescue hotkey) or wait; the log is still written.
set -u
OUT="${1:-$HOME/frl-lt-$(date +%Y%m%d-%H%M%S).log}"
OFF="${OFF_SECONDS:-20}"
DBG=/sys/module/drm/parameters/debug

command -v kscreen-doctor >/dev/null || { echo "kscreen-doctor missing (KDE only)"; exit 1; }
[ -w "$DBG" ] || sudo -v || exit 1
old=$(sudo cat "$DBG")
echo "[frl-capture] drm debug $old -> 0x2 (driver messages) for this cycle only"
echo 0x2 | sudo tee "$DBG" >/dev/null
trap 'echo "$old" | sudo tee "$DBG" >/dev/null; echo "[frl-capture] drm debug restored to $old"' EXIT

T0=$(date '+%Y-%m-%d %H:%M:%S')
echo "[frl-capture] DPMS off for ${OFF}s..."
kscreen-doctor --dpms off >/dev/null 2>&1
sleep "$OFF"
echo "[frl-capture] DPMS on"
kscreen-doctor --dpms on >/dev/null 2>&1
sleep 10

journalctl -k --since "$T0" --no-pager -o short-precise \
  | grep -iE "FRL|hdmi|link training|dc_status|DC_FAIL|DPMS|dpms" > "$OUT"

echo "[frl-capture] $(wc -l < "$OUT") lines -> $OUT"
echo "--- summary ---"
grep -oE "Write link rate = [0-9]+" "$OUT" | sort | uniq -c
grep -cE "PASSED" "$OUT" | sed 's/^/PASSED: /'
grep -E "FAILED|lower link rate|Retry count" "$OUT" | sed 's/.*kernel: //' | sort | uniq -c
echo "--- send the whole file ---"
