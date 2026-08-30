#!/usr/bin/env bash
# Removes everything install-clocklock.sh installed and releases any active lock.
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Run with sudo: sudo bash $0" >&2
    exit 1
fi

/usr/local/bin/blackwell-egpu-clocklock off 2>/dev/null || true
/usr/local/bin/blackwell-egpu-clocklock unpin 2>/dev/null || true

systemctl disable egpu-clocklock.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/egpu-clocklock.service \
      /etc/udev/rules.d/99-egpu-clocklock.rules \
      /etc/sudoers.d/blackwell-egpu-clocklock \
      /usr/local/bin/blackwell-egpu-clocklock
rm -rf /etc/blackwell-egpu /run/blackwell-egpu
systemctl daemon-reload
udevadm control --reload-rules

echo "[+] Clock-lock helper removed; clocks reset to driver defaults."
