#!/usr/bin/env bash
# Watch the amdgpu HDMI FRL path for N seconds WITHOUT touching the display.
#
# Use it on the morning the TV comes up "No Signal": run this first, let it watch for a few
# minutes, and do nothing else. It answers the question the 10-second capture cannot:
#
#   during the dark minutes, does the sink ask for anything (FLT_UPDATE / a retrain request via
#   the FRL status polling workqueue), and does the driver do anything about it -- or is the
#   link completely quiet until the TV silently locks by itself?
#
# Sep 20: the dark screen only happens at HDMI 2.1 (FRL) rates, never at TMDS ones. At the
# moment the source's own view is "everything succeeded" (training PASSED, sink set FRL_START=1)
# while the panel says No Signal for minutes. If the sink is in fact raising FLT_UPDATE during
# those minutes and nothing retrains, that is a driver-side bug we can act on. If the link is
# silent, the fault is entirely inside the TV's FRL receiver.
#
#   bash hdmi-frl-watch.sh            # watch 300 s, log to ~/frl-watch-<stamp>.log
#   bash hdmi-frl-watch.sh 600        # watch 10 minutes
# Note the wall-clock second the picture appears and tell it to the log afterwards; the script
# prints a line every 30 s so the moment can be lined up. Changes nothing; restores drm.debug.
set -u
SECS="${1:-300}"
OUT="${2:-$HOME/frl-watch-$(date +%Y%m%d-%H%M%S).log}"
DBG=/sys/module/drm/parameters/debug

[ -w "$DBG" ] || sudo -v || exit 1
old=$(sudo cat "$DBG")
T0=$(date '+%Y-%m-%d %H:%M:%S')
echo "[frl-watch] drm debug $old -> 0x2 for ${SECS}s; TOUCH NOTHING. Started $T0"
echo 0x2 | sudo tee "$DBG" >/dev/null
trap 'echo "$old" | sudo tee "$DBG" >/dev/null; echo "[frl-watch] drm debug restored"' EXIT

end=$(( $(date +%s) + SECS ))
while [ "$(date +%s)" -lt "$end" ]; do
    sleep 30
    echo "[frl-watch] $(date '+%H:%M:%S')  ($(( (end - $(date +%s)) / 60 )) min left)  -- note the time if the picture appears now"
done

journalctl -k --since "$T0" --no-pager -o short-precise \
  | grep -iE "FRL|hdmi|link training|dc_status|DC_FAIL|dpms|scdc|retrain" > "$OUT"

echo "[frl-watch] $(wc -l < "$OUT") lines -> $OUT"
echo "--- what happened during the watch ---"
grep -cE "FLT_UPDATE = 1" "$OUT" | sed 's/^/sink raised FLT_UPDATE: /'
grep -oE "Write link rate = [0-9]+" "$OUT" | sort | uniq -c
grep -E "PASSED|FAILED|LTS:|FRL_START = 1|lower link rate" "$OUT" | sed 's/.*kernel: //' | sort | uniq -c | head
echo "(no FRL lines at all = the link was silent: the TV locked on its own, source exonerated)"
