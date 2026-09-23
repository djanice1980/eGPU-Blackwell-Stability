#!/usr/bin/env bash
# Install (or remove) the pacman hook that warns when a kernel update has left the patched
# amdgpu module behind. Warning only -- it never builds, installs or changes a module.
#   sudo bash install-amdgpu-frl-check.sh
#   sudo bash install-amdgpu-frl-check.sh --remove
set -euo pipefail
[ "$EUID" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN=/usr/local/bin/amdgpu-frl-override-check
HOOK=/usr/share/libalpm/hooks/amdgpu-frl-override-check.hook

if [ "${1:-}" = "--remove" ]; then
    rm -f "$BIN" "$HOOK"
    echo "[-] Removed the amdgpu FRL override check."
    exit 0
fi

install -o root -g root -m 755 "$D/amdgpu-frl-override-check" "$BIN"
install -D -o root -g root -m 644 "$D/amdgpu-frl-override-check.hook" "$HOOK"
echo "[+] Installed:"
echo "      $BIN"
echo "      $HOOK"
echo "    It prints a warning at the end of any transaction that installs a kernel the patched"
echo "    amdgpu is not built for. Try it now with no side effects:  $BIN"
