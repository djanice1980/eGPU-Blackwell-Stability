#!/usr/bin/env bash
# Log temperatures, fans and APU power every 2 s to a CSV, flushed to disk on every line, so a
# sudden power-off leaves the last readings before it. Written Oct 24 2026 for the folio-closed
# power-offs (asus_wmi "Unknown key code 0x6d" ~1.5 min before each one, no reset reason recorded).
#   bash thermal-logger.sh            log to ~/thermal-<stamp>.csv until Ctrl+C
# The asus_wmi 0x6d events are in the journal: journalctl -k -g "key code 0x6d"
shopt -s nullglob
OUT="${1:-$HOME/thermal-$(date +%Y%m%d-%H%M%S).csv}"

hw() { for h in /sys/class/hwmon/hwmon*; do [ "$(cat $h/name)" = "$1" ] && { echo $h; return; }; done; }
K=$(hw k10temp); G=$(hw amdgpu); A=$(hw asus); N=$(hw nvme); Z=$(hw acpitz)
r() { [ -r "$1" ] && echo $(( $(cat "$1") / ${2:-1000} )) || echo ""; }

echo "time,tctl_c,gpu_edge_c,acpitz1_c,acpitz2_c,acpitz3_c,nvme_c,cpu_fan_rpm,gpu_fan_rpm,apu_ppt_w,profile,lid" > "$OUT"
echo "logging to $OUT (Ctrl+C to stop)"
while :; do
    lid=$(cat /proc/acpi/button/lid/*/state 2>/dev/null | awk '{print $2}')
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$(date +%T)" \
        "$(r $K/temp1_input)" "$(r $G/temp1_input)" \
        "$(r $Z/temp1_input)" "$(r $Z/temp2_input)" "$(r $Z/temp3_input)" "$(r $N/temp1_input)" \
        "$(r $A/fan1_input 1)" "$(r $A/fan2_input 1)" "$(r $G/power1_average 1000000)" \
        "$(cat /sys/firmware/acpi/platform_profile 2>/dev/null)" "$lid" >> "$OUT"
    sync "$OUT"
    sleep 2
done
