#!/usr/bin/env bash
# Append a hardware/driver fingerprint to the manager test log.
#   bash ~/Downloads/manager-test-log.sh <label>      e.g. boot, mode3, after-game, mode6
set -u
LABEL="${1:-snapshot}"
LOG="$HOME/egpu-manager-test-$(date +%Y%m%d).log"
{
echo "################ $LABEL  $(date -Is)"
echo "--- manager state"; cat /tmp/blackwell_egpu/mode 2>/dev/null | sed 's/^/mode=/' ; blackwell-egpu status 2>/dev/null || echo "(blackwell-egpu status unavailable)"
echo "--- udev rule present:"; ls -la /etc/udev/rules.d/99-blackwell-egpu.rules 2>&1
echo "--- PCI: Barlow Ridge bridges + NVIDIA"; lspci -nn | grep -E "8086:5786|10de:" || echo "(none on bus)"
echo "--- link"; for d in $(lspci -D -d 10de: | awk '{print $1}'); do echo -n "$d "; lspci -s "$d" -vv 2>/dev/null | grep -E "LnkSta:" | head -1; done
echo "--- usb4 links"; for p in /sys/bus/thunderbolt/devices/*/usb4_port*; do [ -e "$p/link" ] && echo "$p: $(cat "$p/link")"; done
echo "--- bolt"; boltctl list 2>/dev/null | grep -E "name|status|generation" | head -6
echo "--- root-port runtime PM"; for r in 0000:00:01.1 0000:00:01.2; do echo "$r control=$(cat /sys/bus/pci/devices/$r/power/control 2>/dev/null) status=$(cat /sys/bus/pci/devices/$r/power/runtime_status 2>/dev/null)"; done
echo "--- nvidia"; lsmod | grep -E "^nvidia" | awk '{print $1, $3}'; grep -E "DynamicPowerManagement:" /proc/driver/nvidia/params 2>/dev/null
nvidia-smi --query-gpu=name,pstate,pcie.link.gen.current,pcie.link.width.current,clocks.gr,clocks.mem,clocks.applications.graphics,temperature.gpu --format=csv 2>&1 | head -3
nvidia-smi -q -d CLOCK 2>/dev/null | grep -A2 -E "Locked|Applications Clocks$" | head -8
echo "--- journal (last 40 relevant lines)"; journalctl -b -o short-iso --no-pager 2>/dev/null | grep -iE "Xid|thunderbolt|usb4|nvidia-gpu|NVRM|pageflip|10de|5786|egpu" | tail -40
echo
} | tee -a "$LOG"
echo "-> $LOG"
