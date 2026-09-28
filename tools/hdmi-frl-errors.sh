#!/usr/bin/env bash
# Sample the TV's HDMI 2.1 link-error counters while the picture is ON, read-only.
#
# Why: the watchdog only reads these counters while the sink is unlocked (and once at lock).
# The first capture (2026-09-27 20:19) showed the Reed-Solomon correction counter at 23568 within
# a second of locking at 10G x4, and 0 at 6G x4. That is either the lock-acquisition transient, or a
# link that is marginal at 10G and survives only because forward error correction is working hard --
# which would also be a plausible reason it loses lock at all. Only steady-state samples tell those
# apart: on a healthy link the counts stay at or near zero between samples.
#
# Reads SCDC (I2C address 0x54 on the HDMI connector's DDC bus) with i2ctransfer:
#   0x40      status flags   (clock detect, per-lane lock)
#   0x50-0x5A error counters (lanes 0-3, checksum, Reed-Solomon corrections; 15 bits + valid flag)
# Writes nothing. The kernel serialises every transfer on the bus, so this cannot collide with the
# driver's own 200 ms polling. Needs root for /dev/i2c-*, so it asks for sudo once.
#
#   bash hdmi-frl-errors.sh            12 samples, 10 s apart (2 minutes)
#   bash hdmi-frl-errors.sh 30 5       30 samples, 5 s apart
# Needs i2c-tools (sudo pacman -S --needed i2c-tools) and the i2c-dev module (sudo modprobe i2c-dev).
set -u
N="${1:-12}"; EVERY="${2:-10}"

DDC=""
for c in /sys/class/drm/card*-HDMI-A-*; do
    [ "$(cat "$c/status" 2>/dev/null)" = connected ] || continue
    DDC=$(basename "$(readlink -f "$c/ddc")"); CONN=$(basename "$c"); break
done
[ -n "$DDC" ] || { echo "no connected HDMI output found"; exit 1; }
BUS=${DDC#i2c-}
command -v i2ctransfer >/dev/null || { echo "i2ctransfer missing: sudo pacman -S --needed i2c-tools"; exit 1; }
[ -e "/dev/i2c-$BUS" ] || { echo "/dev/i2c-$BUS missing: sudo modprobe i2c-dev"; exit 1; }
sudo -v || exit 1

echo "connector $CONN, DDC bus i2c-$BUS, SCDC at 0x54 -- $N samples every ${EVERY}s"
echo "counts marked (v) are valid; (-) means the TV says the number is not meaningful right now"
printf '%-8s %-12s %-14s %-14s %-14s %-14s %-16s %s\n' time lanes ln0 ln1 ln2 ln3 rs_corr "rs_corr change"
prev=""
for i in $(seq 1 "$N"); do
    st=$(sudo i2ctransfer -y "$BUS" w1@0x54 0x40 r1 2>/dev/null) || st=""
    ce=$(sudo i2ctransfer -y "$BUS" w1@0x54 0x50 r11 2>/dev/null) || ce=""
    if [ -z "$st" ] || [ -z "$ce" ]; then
        printf '%-8s read failed (the TV did not answer)\n' "$(date +%T)"
    else
        read -r -a b <<< "$ce"
        s=$((st))
        lanes="$(( s>>1&1 ))$(( s>>2&1 ))$(( s>>3&1 ))$(( s>>4&1 ))"
        cnt() { local lo=$(( ${b[$1]} )) hi=$(( ${b[$2]} )); printf '%d%s' $(( lo | (hi & 0x7f) << 8 )) "$( ((hi & 0x80)) && echo '(v)' || echo '(-)')"; }
        rs=$(( ${b[9]} | (${b[10]} & 0x7f) << 8 ))
        delta="-"; [ -n "$prev" ] && delta=$(( rs - prev ))
        printf '%-8s %-12s %-14s %-14s %-14s %-14s %-16s %s\n' "$(date +%T)" "$lanes" \
            "$(cnt 0 1)" "$(cnt 2 3)" "$(cnt 4 5)" "$(cnt 7 8)" "$(cnt 9 10)" "$delta"
        prev=$rs
    fi
    [ "$i" -lt "$N" ] && sleep "$EVERY"
done
echo
echo "Reading it: rs_corr staying at or near 0 = a clean link. rs_corr climbing every sample, or"
echo "pinned at 32767 (the 15-bit ceiling) = the link only holds because error correction is"
echo "working hard; that points at the cable or port at this rate. A count that falls between"
echo "samples means the TV clears the counters when they are read, so each number is per-interval."
