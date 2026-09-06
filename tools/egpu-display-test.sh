#!/usr/bin/env bash
# eGPU display ladder test (v2). Forces a conservative mode on the NVIDIA-attached output the
# moment KWin exposes it, VERIFIES the mode took, and disables the output if it did not.
# Usage:  bash egpu-display-test.sh 1920x1080@60         (SDR, HDR/WCG/VRR off)
#         bash egpu-display-test.sh 3840x2160@60 hdr     (adds HDR+WCG)
# Escape if the screen freezes: pull the HDMI cable out of the eGPU (NOT the TB cable).
#
# v2, after the Sep 5 22:30 freeze: v1 never applied 1080p60 (kscreen-doctor errors were
# hidden and KWin had not registered the output yet), so the monitor came up at the eGPU's
# default 4K120 with NO clock lock -> Xid 154 at +13 s -> pageflip timeouts -> hard freeze.
# v2 refuses to run unlocked, resolves the mode by id from KWin's own list, verifies the
# applied mode, and disables the eGPU output on a mismatch or on the first loss signature.
set -u
MODE="${1:-1920x1080@60}"; HDR="${2:-}"
LOG="$HOME/egpu-display-test-$(date +%Y%m%d-%H%M%S).log"
say(){ echo "$*" | tee -a "$LOG"; }
strip(){ sed 's/\x1b\[[0-9;]*m//g'; }
modes_of(){ kscreen-doctor -o 2>/dev/null | strip | awk -v o="$1" '$1=="Output:" {on=($3==o)} on && $1=="Modes:" {print}' | tr ' \t' '\n\n' | grep -E '^[0-9]+:[0-9]+x[0-9]+@'; }

# 0. preconditions: driver up, clocks locked (P0 with graphics clock >= 1900 MHz at idle)
PS=$(nvidia-smi --query-gpu=pstate,clocks.gr,clocks.mem --format=csv,noheader,nounits 2>/dev/null | tr -d ' ')
say "mode=$MODE hdr=${HDR:-off} gpu=[${PS:-none}] dpm=$(grep -oE 'DynamicPowerManagement: [0-9]+' /proc/driver/nvidia/params 2>/dev/null) $(date -Is)"
[ -n "$PS" ] || { say "ABORT: nvidia-smi cannot see the GPU. Attach it first."; exit 1; }
IFS=, read -r PST GCLK MCLK <<< "$PS"
if [ "$PST" != "P0" ] || [ "${GCLK:-0}" -lt 1900 ]; then
    say "ABORT: clocks are not locked (pstate=$PST gr=${GCLK} MHz). Lock first:"
    say "  sudo nvidia-smi --lock-gpu-clocks=2000,3210 && sudo nvidia-smi --lock-memory-clocks=14001,14001"
    exit 1
fi
kscreen-doctor -o 2>/dev/null | strip | grep -q "^Output: .* eDP-1" || say "WARNING: eDP-1 not listed; you have no fallback screen."

# 1. wait for the NVIDIA-driven connector in sysfs, then for KWin to expose it
say "Plug the monitor into the 5070 Ti now. Waiting for an NVIDIA-driven output..."
OUT=""
for i in $(seq 1 120); do
    for c in /sys/class/drm/card*-*; do
        drv=$(basename "$(readlink -f "$c/../device/driver" 2>/dev/null)" 2>/dev/null)
        if [ "$drv" = "nvidia" ] && [ "$(cat "$c/status" 2>/dev/null)" = "connected" ]; then
            OUT=$(basename "$c" | sed -E 's/^card[0-9]+-//'); break 2
        fi
    done
    sleep 1
done
[ -n "$OUT" ] || { say "No NVIDIA-driven connector appeared in 120 s."; exit 1; }
say "sysfs: NVIDIA connector $OUT. Waiting for KWin to register it..."
KOUT=""
for i in $(seq 1 40); do
    KOUT=$(kscreen-doctor -o 2>/dev/null | strip | awk '$1=="Output:" {print $3}' | grep -x "$OUT" | head -1)
    [ -n "$KOUT" ] && [ -n "$(modes_of "$KOUT")" ] && break
    sleep 0.5
done
[ -n "$KOUT" ] || { say "KWin never listed $OUT (check 'kscreen-doctor -o'). Aborting before any mode is set."; exit 1; }

# 2. resolve the requested mode to KWin's mode id (exact refresh preferred, e.g. 60.00 over 59.94)
WANT_WH=${MODE%@*}; WANT_R=${MODE#*@}; WANT_R=${WANT_R%%.*}
MID=$(modes_of "$KOUT" | grep -E "^[0-9]+:${WANT_WH}@${WANT_R}(\.0+)?$" | head -1 | cut -d: -f1)
[ -n "$MID" ] || MID=$(modes_of "$KOUT" | grep -E "^[0-9]+:${WANT_WH}@${WANT_R}\." | head -1 | cut -d: -f1)
if [ -z "$MID" ]; then
    say "No mode ${WANT_WH}@${WANT_R} on $KOUT. Available:"; modes_of "$KOUT" | tr '\n' ' ' | tee -a "$LOG"; echo
    say "Disabling $KOUT so it does not stay at its default mode."; kscreen-doctor "output.$KOUT.disable" 2>&1 | strip | tee -a "$LOG"
    exit 1
fi
say "Applying mode id $MID ($(modes_of "$KOUT" | grep -E "^$MID:" | cut -d: -f2)) on $KOUT, vrr never, hdr ${HDR:-off}"
kscreen-doctor "output.$KOUT.enable" "output.$KOUT.mode.$MID" 2>&1 | strip | tee -a "$LOG"   # .enable is required: a prior abort/run may have left the connector disabled (KWin reports the mode 'active' but the kernel keeps status=connected enabled=disabled -> no signal). VRR is 'Never' by default here.
if [ "$HDR" = "hdr" ]; then
    kscreen-doctor "output.$KOUT.hdr.enable" "output.$KOUT.wcg.enable" 2>&1 | strip | tee -a "$LOG"
else
    kscreen-doctor "output.$KOUT.hdr.disable" "output.$KOUT.wcg.disable" 2>&1 | strip | tee -a "$LOG"
fi
sleep 3
CUR=$(modes_of "$KOUT" | grep '\*' | head -1 | cut -d: -f2 | sed 's/\*!\?$//')
say "Applied mode on $KOUT: ${CUR:-unknown}   HDR: $(kscreen-doctor -o 2>/dev/null | strip | awk -v o="$KOUT" '$1=="Output:" {on=($3==o)} on && $1=="HDR:" {print $2}')"
CUR_R=${CUR#*@}; CUR_R=${CUR_R%%.*}
if [ "${CUR%@*}" != "$WANT_WH" ] || [ "$CUR_R" != "$WANT_R" ]; then
    say "MODE MISMATCH (wanted ${WANT_WH}@${WANT_R}, got ${CUR:-none}). Disabling $KOUT so the eGPU does not scan out at the wrong mode."
    kscreen-doctor "output.$KOUT.disable" 2>&1 | strip | tee -a "$LOG"
    say "Move the HDMI cable back to the laptop and send me this log."
    exit 1
fi

# 3. watch; on the first loss signature drop the eGPU output immediately (best effort)
say "Mode verified. Keep something MOVING full-screen on that monitor for ~10 min. Watching (Ctrl-C to stop)..."
START=$(date +%s)
journalctl -f -o short-iso 2>/dev/null | grep --line-buffered -iE "Xid|Pageflip timed out|Flip event timeout|Lost display notification|detector_class|MMU Fault|GPU 0 lost" | while read -r line; do
    say "[$(( $(date +%s) - START )) s] $line"
    case "$line" in
        *Xid*|*detector_class*|*"GPU 0 lost"*)
            say "LOSS SIGNATURE -> disabling $KOUT now. If the screen is stuck, pull the HDMI from the eGPU."
            timeout 5 kscreen-doctor "output.$KOUT.disable" >/dev/null 2>&1 ;;
    esac
done
