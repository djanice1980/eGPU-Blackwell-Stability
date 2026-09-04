#!/usr/bin/env bash
# Repeatable DPMS wake test. Blanks all displays, waits, wakes them, then asks
# whether the EXTERNAL display came back. Logs results for the bug report.
# Usage: bash dpms-cycle.sh [cycles]   (default 5). No sudo needed.
set -u
N="${1:-5}"
LOG="$HOME/dpms-cycle-$(date +%Y%m%d-%H%M).log"
MODE=$(kscreen-doctor -o 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -oE "[0-9]+x[0-9]+@[0-9.]+\*" | head -1)
HDR=$(kscreen-doctor -o 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -m1 "HDR:" | awk '{print $2}')
MASK=$(cat /sys/module/amdgpu/parameters/dcdebugmask 2>/dev/null)
{
  echo "kernel=$(uname -r) dcdebugmask=$MASK mode=$MODE hdr=$HDR cycles=$N date=$(date -Is)"
} | tee "$LOG"
pass=0; fail=0
for i in $(seq 1 "$N"); do
  echo "--- cycle $i/$N: blanking in 2 s (don't touch anything) ---"
  sleep 2
  kscreen-doctor --dpms off >/dev/null 2>&1
  sleep 8
  kscreen-doctor --dpms on  >/dev/null 2>&1
  sleep 3
  read -r -p "cycle $i: did the EXTERNAL display come back? [y/n] " a
  if [[ "$a" =~ ^[Yy] ]]; then pass=$((pass+1)); r=PASS; else fail=$((fail+1)); r=FAIL; fi
  echo "cycle $i $r" | tee -a "$LOG"
  if [ "$r" = FAIL ]; then
    echo "  (press Meta+Shift+D to recover, then press Enter to continue)"; read -r _
  fi
done
echo "RESULT: pass=$pass fail=$fail (mode=$MODE hdr=$HDR dcdebugmask=$MASK)" | tee -a "$LOG"
echo "log: $LOG"
