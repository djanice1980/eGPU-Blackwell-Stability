#!/usr/bin/env bash
# Undo manager-test-prep.sh: put our eGPU config files back and reload udev.
# Run Damian's ./uninstall.sh separately (answer Y to "Remove udev rules?").
#   bash ~/Downloads/manager-test-restore.sh
set -euo pipefail
[ "$EUID" -ne 0 ] || { echo "Run as your normal user, not root."; exit 1; }
BACKUP="$HOME/egpu-manager-test-backup"
declare -A DEST=(
  [zz-nvidia-egpu.conf]=/etc/modprobe.d/zz-nvidia-egpu.conf
  [99-usb4-tunnel-ports-awake.rules]=/etc/udev/rules.d/99-usb4-tunnel-ports-awake.rules
)
sudo -v
for name in "${!DEST[@]}"; do
    src="$BACKUP/$name.moved"; [ -e "$src" ] || src="$BACKUP/$name"
    if [ -e "$src" ]; then
        sudo install -o root -g root -m 644 "$src" "${DEST[$name]}"
        echo "restored ${DEST[$name]}"
    else
        echo "no backup for $name in $BACKUP (nothing restored)"
    fi
done
sudo udevadm control --reload-rules
if [ -f /etc/udev/rules.d/99-blackwell-egpu.rules ] || [ -f /etc/sudoers.d/blackwell-egpu ]; then
    echo "Damian's manager is still installed: run  cd ~/Downloads/blackwell-egpu-manager && ./uninstall.sh  (Y to remove udev rules)"
fi
echo "Reboot so DynamicPowerManagement=0 from zz-nvidia-egpu.conf is in effect again; verify with:"
echo "  grep DynamicPowerManagement /proc/driver/nvidia/params"
