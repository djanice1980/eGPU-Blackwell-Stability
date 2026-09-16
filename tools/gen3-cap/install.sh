#!/usr/bin/env bash
# Install (or remove) the Gen3 bridge cap + late NVIDIA load. Run with sudo.
#   sudo bash install.sh            install
#   sudo bash install.sh --remove   remove everything it added
# What it installs:
#   /usr/local/bin/nvidia-egpu-cap-and-load        cap the port above the GPU at Gen3, retrain, load nvidia
#   /usr/local/bin/nvidia-egpu-unload              unload nvidia when the GPU leaves the bus
#   /etc/systemd/system/nvidia-egpu-cap-and-load.service
#   /etc/udev/rules.d/99-nvidia-egpu-cap-and-load.rules   (add -> the service, remove -> unload)
#   /etc/modprobe.d/zz-nvidia-egpu-lateload.conf   blacklist nvidia* for udev AUTOLOAD only
#      (explicit modprobe from the service still works), then rebuilds the initramfs so the
#      blacklist also applies to early-boot udev (mkinitcpio's modconf hook copies modprobe.d).
# Nothing else is changed. Kernel cmdline untouched. COLD BOOT ONLY: reboot with the enclosure
# attached to activate; do not hot-plug.
set -euo pipefail
[ "$EUID" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BL=/etc/modprobe.d/zz-nvidia-egpu-lateload.conf

rebuild_initramfs() {
    if command -v limine-mkinitcpio >/dev/null 2>&1; then limine-mkinitcpio; else mkinitcpio -P; fi
}

if [ "${1:-}" = "--remove" ]; then
    rm -f /etc/udev/rules.d/99-nvidia-egpu-cap-and-load.rules /etc/systemd/system/nvidia-egpu-cap-and-load.service \
          /usr/local/bin/nvidia-egpu-cap-and-load /usr/local/bin/nvidia-egpu-unload "$BL"
    systemctl daemon-reload; udevadm control --reload-rules
    rebuild_initramfs
    echo "[-] Removed. nvidia autoloads again from the next reboot; the link returns to Gen4."
    exit 0
fi

command -v setpci >/dev/null || { echo "pciutils (setpci) missing: sudo pacman -S pciutils" >&2; exit 1; }
install -o root -g root -m 755 "$D/nvidia-egpu-cap-and-load" /usr/local/bin/nvidia-egpu-cap-and-load
install -o root -g root -m 755 "$D/nvidia-egpu-unload"       /usr/local/bin/nvidia-egpu-unload
install -o root -g root -m 644 "$D/nvidia-egpu-cap-and-load.service" /etc/systemd/system/nvidia-egpu-cap-and-load.service
install -o root -g root -m 644 "$D/99-nvidia-egpu-cap-and-load.rules" /etc/udev/rules.d/99-nvidia-egpu-cap-and-load.rules
printf '%s\n' \
  '# Late-load the NVIDIA modules: block udev/modalias AUTOLOAD so the GPU is not bound before' \
  '# nvidia-egpu-cap-and-load.service has capped the link above it at Gen3. Explicit modprobe' \
  '# (which that service does) is unaffected by blacklist lines. Installed by tools/gen3-cap.' \
  'blacklist nvidia' 'blacklist nvidia_modeset' 'blacklist nvidia_drm' 'blacklist nvidia_uvm' 'blacklist nvidia_peermem' > "$BL"
systemctl daemon-reload
udevadm control --reload-rules
rebuild_initramfs
echo "[+] Installed. Activates on the next COLD BOOT with the enclosure attached (do not hot-plug)."
echo "    After boot:  journalctl -b -t nvidia-egpu-cap --no-pager"
echo "                 sudo nvidia-egpu-cap-and-load --status"
echo "    Expected: bridge and GPU LnkSta at Gen3 x4, driver=nvidia, nvidia-smi pcie.link.gen.current = 3."
echo "    Remove:   sudo bash $D/install.sh --remove   (then reboot)"
