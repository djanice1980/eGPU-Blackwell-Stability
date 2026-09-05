#!/usr/bin/env bash
# Mode 3 attach retry (v3). Root cause seen in the journal: a sysfs rescan of the root
# port sizes the Barlow Ridge switch's bridge windows BEFORE the GPU port link is trained,
# so the GPU shows up later with no room for its ~640 MB of BARs -> "BAR0 is 0M".
# Remedy: once the GPU link is up, remove the switch's upstream port and rescan the root
# port again so the whole tree is sized with the GPU present (what pciehp does at boot).
# Damian's udev rule needs /tmp/egpu_allow present during this, same as his set3.
#   sudo bash ~/Downloads/manager-mode3-retry.sh
set -u
[ "$EUID" -eq 0 ] || { echo "run with sudo"; exit 1; }
RP=0000:00:01.2                 # AMD root port the USB4 PCIe tunnel hangs off
ALLOW=/tmp/egpu_allow
log(){ echo "[$(date +%T)] $*"; }
gpu_bdf(){ lspci -D -d 10de: -nn 2>/dev/null | grep -iE "VGA|3D" | awk '{print $1}' | head -1; }
upstream(){ lspci -D -d 8086:5786 2>/dev/null | awk '{print $1}' | sort | head -1; }
gpuport(){ lspci -D -d 8086:5786 2>/dev/null | awk '{print $1}' | sort | sed -n 2p; }   # first downstream = GPU slot
bar0_ok(){  # true only if BAR0 has a real address (sysfs resource line 1 is "start end flags")
    [ -n "${1:-}" ] || return 1
    local start; start=$(head -1 "/sys/bus/pci/devices/$1/resource" 2>/dev/null | awk '{print $1}')
    [ -n "$start" ] && [ "$start" != "0x0000000000000000" ]
}
linkstate(){  # LnkSta: bit13 = Data Link Layer Active, bits0-3 speed, bits4-9 width
    local v; v=$(setpci -s "$1" CAP_EXP+12.w 2>/dev/null) || { echo "n/a"; return; }
    v=$((16#$v)); printf 'LnkSta=0x%04x DLActive=%d speed=%d width=x%d' "$v" $(( (v>>13)&1 )) $((v&0xf)) $(( (v>>4)&0x3f ))
}

log "before: gpu=${GPU:=$(gpu_bdf)} upstream=$(upstream) gpuport=$(gpuport)"
[ -n "$(gpuport)" ] && log "GPU port link now: $(linkstate "$(gpuport)")"
grep -E "DynamicPowerManagement:" /proc/driver/nvidia/params 2>/dev/null
touch "$ALLOW"

for WAIT in 3 8 15; do
    G=$(gpu_bdf)
    if bar0_ok "$G"; then log "GPU $G has BAR0 assigned - attach OK"; break; fi

    if [ -z "$G" ]; then
        DS=$(gpuport)
        if [ -n "$DS" ]; then
            log "no GPU on bus; GPU port $DS: $(linkstate "$DS") -> rescanning that port"
            echo 1 > "/sys/bus/pci/devices/$DS/rescan" 2>/dev/null
            sleep 1; G=$(gpu_bdf)
            log "after port rescan: gpu=${G:-none}"
            if bar0_ok "$G"; then log "GPU $G has BAR0 assigned - attach OK"; break; fi
        fi
    fi

    UP=$(upstream)
    log "full pass: remove upstream $UP, wait ${WAIT}s for the GPU link, rescan root port $RP"
    [ -n "$UP" ] && echo 1 > "/sys/bus/pci/devices/$UP/remove"
    sleep "$WAIT"
    echo 1 > "/sys/bus/pci/devices/$RP/rescan"
    udevadm settle --timeout=5; sleep 2
    G=$(gpu_bdf)
    log "after root-port rescan: gpu=${G:-none}"
    [ -n "$G" ] && lspci -vv -s "$G" 2>/dev/null | grep -E "Region 0|Region 1|Kernel driver" | sed 's/^/    /'
done
rm -f "$ALLOW"

G=$(gpu_bdf)
if bar0_ok "$G"; then
    log "finishing his Mode 3: modeset/drm/uvm, persistence, clock lock"
    modprobe nvidia_modeset nvidia_drm nvidia_uvm 2>/dev/null
    udevadm settle --timeout=5; sleep 2
    nvidia-smi -pm 1 >/dev/null 2>&1
    MAXG=$(nvidia-smi --query-gpu=clocks.max.graphics --format=csv,noheader,nounits 2>/dev/null | tr -d ' ')
    MAXM=$(nvidia-smi --query-gpu=clocks.max.memory   --format=csv,noheader,nounits 2>/dev/null | tr -d ' ')
    nvidia-smi --lock-gpu-clocks="2000,${MAXG:-3090}" >/dev/null 2>&1
    nvidia-smi --lock-memory-clocks="${MAXM:-14001},${MAXM:-14001}" >/dev/null 2>&1
    nvidia-smi --query-gpu=name,pstate,pcie.link.gen.current,pcie.link.width.current,clocks.gr,clocks.mem --format=csv
else
    log "GPU still without BAR0 after 3 passes - stop and report"
fi
dmesg | grep -E "NVRM|Xid|BAR0|nvidia 0000" | tail -6
