#!/usr/bin/env bash
# Installs the clock-lock helper for the Blackwell eGPU Status widget.
# Run with sudo. Installs:
#   /usr/local/bin/blackwell-egpu-clocklock   (root-owned helper)
#   /etc/sudoers.d/blackwell-egpu-clocklock   (NOPASSWD for the FOUR literal
#                                              commands only, validated with visudo)
#   /etc/systemd/system/egpu-clocklock.service (boot-time pin apply)
#   /etc/udev/rules.d/99-egpu-clocklock.rules  (re-apply on nvidia driver bind)
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Run with sudo: sudo bash $0" >&2
    exit 1
fi

TARGET_USER="${SUDO_USER:-}"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    echo "Could not determine the invoking user (run via sudo, not as root login)." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Installing helper ==="
install -o root -g root -m 755 "$SCRIPT_DIR/blackwell-egpu-clocklock" /usr/local/bin/blackwell-egpu-clocklock

echo "=== Installing sudoers entry (scoped to literal commands) ==="
SUDOERS_TMP=$(mktemp)
{
    echo "$TARGET_USER ALL=(root) NOPASSWD: /usr/local/bin/blackwell-egpu-clocklock on"
    echo "$TARGET_USER ALL=(root) NOPASSWD: /usr/local/bin/blackwell-egpu-clocklock off"
    echo "$TARGET_USER ALL=(root) NOPASSWD: /usr/local/bin/blackwell-egpu-clocklock pin"
    echo "$TARGET_USER ALL=(root) NOPASSWD: /usr/local/bin/blackwell-egpu-clocklock unpin"
} > "$SUDOERS_TMP"
visudo -cf "$SUDOERS_TMP"   # refuse to install a broken sudoers file
install -o root -g root -m 440 "$SUDOERS_TMP" /etc/sudoers.d/blackwell-egpu-clocklock
rm -f "$SUDOERS_TMP"

echo "=== Installing systemd service + udev rule ==="
install -o root -g root -m 644 "$SCRIPT_DIR/egpu-clocklock.service" /etc/systemd/system/egpu-clocklock.service
install -o root -g root -m 644 "$SCRIPT_DIR/99-egpu-clocklock.rules" /etc/udev/rules.d/99-egpu-clocklock.rules
systemctl daemon-reload
systemctl enable egpu-clocklock.service >/dev/null 2>&1
udevadm control --reload-rules

echo ""
echo "[+] Installed. The widget's Clock lock / Pin toggles are now live."
echo "    Uninstall with: sudo bash $SCRIPT_DIR/uninstall-clocklock.sh"
