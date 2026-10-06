#!/usr/bin/env bash
# Install (or remove) the pacman hook that builds and installs the patched amdgpu for every new
# kernel during the update itself (see amdgpu-frl-rebuild for how).
#   sudo bash install-amdgpu-frl-rebuild.sh            builds as $SUDO_USER (override: BUILD_USER=...)
#   sudo bash install-amdgpu-frl-rebuild.sh --remove
# It supersedes the warning-only amdgpu-frl-override-check hook (the rebuild hook prints the same
# warning when a build fails) and removes that hook's two files if they are installed -- nothing else.
set -euo pipefail
[ "$EUID" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$D/.." && pwd)"
BIN=/usr/local/bin/amdgpu-frl-rebuild
HOOK=/usr/share/libalpm/hooks/zy-amdgpu-frl-rebuild.hook
CONF=/etc/amdgpu-frl-rebuild.conf
OLD_BIN=/usr/local/bin/amdgpu-frl-override-check
OLD_HOOK=/usr/share/libalpm/hooks/amdgpu-frl-override-check.hook

if [ "${1:-}" = "--remove" ]; then
    rm -f "$BIN" "$HOOK" "$CONF"
    echo "[-] Removed the amdgpu FRL rebuild hook ($BIN, $HOOK, $CONF)."
    exit 0
fi

U="${BUILD_USER:-${SUDO_USER:-}}"
if [ -z "$U" ] || [ "$U" = root ]; then
    echo "Could not tell which user owns ~/kbuild -- run as: sudo BUILD_USER=<you> bash $0" >&2
    exit 1
fi
UHOME=$(getent passwd "$U" | cut -d: -f6)
[ -d "$UHOME/kbuild/linux-cachyos/.git" ] || echo "note: $UHOME/kbuild/linux-cachyos is not a CachyOS PKGBUILD checkout yet (see tools/amdgpu-frl-module/build.sh header)"

install -o root -g root -m 755 "$D/amdgpu-frl-rebuild" "$BIN"
install -D -o root -g root -m 644 "$D/zy-amdgpu-frl-rebuild.hook" "$HOOK"
printf 'BUILD_USER=%q\nREPO=%q\n' "$U" "$REPO" > "$CONF"
chmod 644 "$CONF"
for f in "$OLD_BIN" "$OLD_HOOK"; do [ -e "$f" ] && rm -f "$f" && echo "[-] removed superseded $f"; done

echo "[+] Installed:"
echo "      $BIN"
echo "      $HOOK"
echo "      $CONF  (BUILD_USER=$U)"
echo "    Every linux-cachyos install/upgrade now builds and installs the patched amdgpu for the new"
echo "    kernel before you reboot. Run it now to cover any kernel that is missing it:"
echo "      sudo $BIN"
