#!/usr/bin/env bash
# Installs the pacman hook that rebuilds the patched NVIDIA modules on every
# kernel update, closing the "rebooted into a driverless kernel" gap.
# Run with sudo. Optionally pass the driver tree path as $1
# (default: the invoking user's ~/open-gpu-kernel-modules).
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Run with sudo: sudo bash $0" >&2
    exit 1
fi

TARGET_USER="${SUDO_USER:-}"
[ -n "$TARGET_USER" ] && [ "$TARGET_USER" != "root" ] || { echo "Run via sudo from your user account." >&2; exit 1; }

USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
TREE="${1:-$USER_HOME/open-gpu-kernel-modules}"
[ -d "$TREE" ] || { echo "Driver tree not found at $TREE (pass the path as an argument)." >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install -o root -g root -m 755 "$SCRIPT_DIR/nvidia-egpu-rebuild" /usr/local/bin/nvidia-egpu-rebuild
mkdir -p /etc/pacman.d/hooks
install -o root -g root -m 644 "$SCRIPT_DIR/nvidia-egpu-rebuild.hook" /etc/pacman.d/hooks/nvidia-egpu-rebuild.hook
printf 'TREE=%s\nBUILD_USER=%s\nKERNEL_PKG=linux-cachyos\nKERNEL_SUFFIX=cachyos\n' \
    "$TREE" "$TARGET_USER" > /etc/nvidia-egpu-rebuild.conf
chmod 644 /etc/nvidia-egpu-rebuild.conf

echo "[+] Hook installed. Kernel upgrades now rebuild the patched modules in-transaction."
echo "    Dry-run it now against the current kernel: sudo nvidia-egpu-rebuild"
echo "    (should report 'already installed -- nothing to do')"
echo "    Uninstall: sudo rm /etc/pacman.d/hooks/nvidia-egpu-rebuild.hook /usr/local/bin/nvidia-egpu-rebuild /etc/nvidia-egpu-rebuild.conf"
