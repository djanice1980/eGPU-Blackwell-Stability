#!/usr/bin/env bash
# Capture amdgpu's HDMI FRL link-training trace across a 4K60 -> 4K120 mode switch, repeatedly.
#
# Why: every slow recovery on record is at 10G x4 (4K120), and the login-time switch from 4K60
# (6G x4) to 4K120 is the most reliable way to get one (Sep 27: 21:37 needed 2 link re-enables and
# 8.9 s, 22:05 needed 3 and 11.2 s; 6G x4 locks in about a second). The driver keeps the stream up
# at rate 5, i.e. it counts the training as done, yet the TV reports no lane locked until a second
# or third full re-enable. The training messages that would say what happened are drm_dbg() and
# silent by default. This turns them on (drm.debug=0x2) only for each switch to 4K120, then off.
#
# Each cycle: switch to 4K60, wait for the TV to lock, debug on, switch to 4K120, wait for lock
# (or LOCK_TIMEOUT), debug off, then summarise that cycle. The patched module's watchdog logs every
# poll while debug is on ("FRL WATCHDOG: ... status=0x..") so the log shows the TV's lock state
# every 200 ms next to each training step.
#
# What the per-cycle timeline means (messages from link_hdmi_frl.c):
#   Starting FRL Link Training / Write link rate = 5    a training at 10G x4 began
#   Read FRL_START = 1                                  the TV accepted the training (LTS:P)
#   PASSED                                              the driver counts the link as trained
#   FAILED - Timeout waiting for FLT_UPDATE / FLT_READY not set / lower link rate
#   Retry count = N out of M                            training retries inside ONE enable
#   re-enabling the link (attempt N)                    the watchdog's full re-enable (patch 0003)
#   sink state changed -- status=0x5e / 0x40            TV locked (four lanes) / not locked
# The question it answers: after a PASSED at rate 5, does the TV go 0x5e and then drop, or never
# lock at all -- and does the training that finally works differ from the ones that do not?
#
# Run from the desktop session as your user (kscreen-doctor needs the session). Needs sudo once
# (drm debug parameter) and python3 (to read kscreen-doctor's JSON; CachyOS ships it).
#   bash hdmi-frl-switch-capture.sh                  3 cycles, log to ~/frl-switch-<stamp>.log
#   CYCLES=5 bash hdmi-frl-switch-capture.sh
#   OUTPUT=HDMI-A-1 FROM_MODE=1 TO_MODE=13 bash hdmi-frl-switch-capture.sh   (ids: kscreen-doctor -o)
# The external screen goes dark for a few seconds on every switch, longer when the fault hits;
# the watchdog brings it back. At the end the original mode is restored.
set -u
OUT="${1:-$HOME/frl-switch-$(date +%Y%m%d-%H%M%S).log}"
CYCLES="${CYCLES:-3}"
LOCK_TIMEOUT="${LOCK_TIMEOUT:-120}"   # the watchdog does 12 attempts ~4.5 s apart, then 1/min
DBG=/sys/module/drm/parameters/debug

say() { echo "[frl-switch] $*"; }
command -v kscreen-doctor >/dev/null || { say "kscreen-doctor missing (KDE only)"; exit 1; }
command -v python3 >/dev/null || { say "python3 missing: sudo pacman -S --needed python"; exit 1; }
strings "$(modinfo -n amdgpu)" 2>/dev/null | grep -q "sink raised %s" \
    || say "WARNING: the loaded amdgpu is not the patched build (patch 0003 point 6); the log will lack the watchdog lines"

# --- pick the output and the two modes -------------------------------------------------------
read -r OUTNAME ORIG FROM TO < <(kscreen-doctor -j 2>/dev/null | python3 -c '
import json, os, sys
d = json.load(sys.stdin)
want = os.environ.get("OUTPUT")
for o in d["outputs"]:
    if not o.get("connected") or not o.get("enabled"): continue
    if want and o["name"] != want: continue
    if not want and not o["name"].startswith("HDMI"): continue
    def pick(hz):
        c = [m for m in o["modes"] if m["size"]["width"] == 3840 and m["size"]["height"] == 2160
             and abs(m["refreshRate"] - hz) < 0.01]
        return c[0]["id"] if c else "-"
    print(o["name"], o.get("currentModeId", "-"),
          os.environ.get("FROM_MODE") or pick(60), os.environ.get("TO_MODE") or pick(120))
    break
')
[ -n "${OUTNAME:-}" ] || { say "no enabled HDMI output found (set OUTPUT=...)"; exit 1; }
[ "$FROM" != "-" ] && [ "$TO" != "-" ] || { say "$OUTNAME has no exact 3840x2160@60 and @120 modes; set FROM_MODE/TO_MODE (kscreen-doctor -o)"; exit 1; }
say "output $OUTNAME: current mode $ORIG, switching $FROM (4K60) -> $TO (4K120), $CYCLES cycle(s)"

sudo -v || exit 1
OLD_DBG=$(sudo cat "$DBG") || OLD_DBG=""
# the parameter is root-only (0600); an empty read would make every restore write "" (EINVAL)
# and leave debug on, flooding the log (Sep 28 first run). No drm.debug on the cmdline = 0.
[ -n "$OLD_DBG" ] || OLD_DBG=0
restore() {
    echo "$OLD_DBG" | sudo tee "$DBG" >/dev/null
    [ "$ORIG" != "-" ] && kscreen-doctor "output.$OUTNAME.mode.$ORIG" >/dev/null 2>&1
    say "drm debug restored to $OLD_DBG, mode $ORIG restored"
}
trap restore EXIT

# The TV's lock state as the watchdog last logged it. It logs only on change, so the newest line
# since $1 is the current state. If a switch never showed the watchdog an unlocked poll there is no
# line since $1; after 3 s, fall back to the newest line this boot (the state it has held since).
lock_state() {
    local since="$1" t="$2" last
    last=$(journalctl -k --since "$since" --no-pager -o cat 2>/dev/null \
           | grep "HDMI FRL: sink state changed" | tail -1)
    if [ -z "$last" ] && [ "$t" -ge 3 ]; then
        last=$(journalctl -k --no-pager -o cat 2>/dev/null \
               | grep "HDMI FRL: sink state changed" | tail -1)
    fi
    case "$last" in *status=0x5e*) echo locked ;; *) echo unlocked ;; esac
}

# Wait until the TV reports lock and holds it for 2 s. Echoes the seconds waited; 1 on timeout.
wait_lock() {
    local since="$1" limit="$2" t=0
    while [ "$t" -lt "$limit" ]; do
        sleep 1; t=$((t + 1))
        if [ "$(lock_state "$since" "$t")" = locked ]; then
            sleep 2
            [ "$(lock_state "$since" "$((t + 2))")" = locked ] && { echo "$t"; return 0; }
        fi
    done
    echo "$t"; return 1
}

: > "$OUT"
for c in $(seq 1 "$CYCLES"); do
    say "cycle $c: -> 4K60"
    T60=$(date '+%Y-%m-%d %H:%M:%S')
    kscreen-doctor "output.$OUTNAME.mode.$FROM" >/dev/null 2>&1
    sleep 3
    if ! w=$(wait_lock "$T60" 60); then
        say "cycle $c: TV not locked at 4K60 after ${w}s -- skipping this cycle"
        continue
    fi
    sleep 3

    echo 0x2 | sudo tee "$DBG" >/dev/null
    T0=$(date '+%Y-%m-%d %H:%M:%S.%N' | cut -c1-23)
    say "cycle $c: -> 4K120 (debug on)"
    kscreen-doctor "output.$OUTNAME.mode.$TO" >/dev/null 2>&1
    sleep 2
    if w=$(wait_lock "$T0" "$LOCK_TIMEOUT"); then res="locked after ~$((w + 2)) s"; else res="NOT locked after ${LOCK_TIMEOUT} s"; fi
    sleep 2
    echo "$OLD_DBG" | sudo tee "$DBG" >/dev/null
    say "cycle $c: $res (debug off)"

    {
        echo "===== cycle $c: $FROM -> $TO at $T0 -- $res"
        journalctl -k --since "$T0" --no-pager -o short-precise \
            | grep -E "FRL|HDMI|[Ll]ink [Tt]raining|DC_FAIL|dc_status|DMCUB|Missed|suppressed"
    } >> "$OUT"

    # per-cycle summary, from this cycle's section only
    sec=$(awk -v h="===== cycle $c:" 'index($0,h)==1{p=1} p' "$OUT")
    echo "--- cycle $c summary ($res) ---"
    echo "  trainings started:  $(grep -c "Starting FRL Link Training" <<< "$sec")"
    echo "  link rates written: $(grep -oE "Write link rate = [0-9]+" <<< "$sec" | awk '{print $NF}' | sort | uniq -c | xargs)"
    echo "  PASSED:             $(grep -c "LINK TRAINING:  PASSED" <<< "$sec")"
    grep -E "FAILED|lower link rate|Fall ?back" <<< "$sec" | sed 's/.*LINK TRAINING: *//' | sort | uniq -c | sed 's/^/  /'
    echo "  watchdog re-enables: $(grep -c "re-enabling the link" <<< "$sec"), skipped for a commit: $(grep -c "skipped this pass" <<< "$sec")"
    grep -qE "Missed|suppressed" <<< "$sec" && echo "  NOTE: the kernel log dropped messages in this window; the timeline may have gaps"
    echo "  timeline:"
    grep -E "Starting FRL Link Training|Write link rate|FRL_START = 1|PASSED|FAILED|lower link rate|Retry count|re-enabling the link|skipped this pass|sink state changed|lock restored|sink locked|sink raised|cleared after" <<< "$sec" \
        | sed -E 's/^([A-Za-z]+ [0-9]+ )?([0-9:.]+) .*(FRL LINK TRAINING:|HDMI FRL:) */    \2  /'
    sleep 3
done

echo
say "$(wc -l < "$OUT") lines -> $OUT"
say "send the whole file"
