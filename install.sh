#!/usr/bin/env bash
# eGPU-Blackwell-Stability unified installer.
#
#   ./install.sh              interactive: offers each component
#   ./install.sh --all        install patches + widget + clocklock helper
#   ./install.sh --patches    patched driver modules only
#   ./install.sh --widget     Plasma 6 status widget only (user-level, no root)
#   ./install.sh --clocklock  clock-lock helper only (root, scoped sudoers)
#   ./install.sh --check      report system state, change nothing
#
# Run as a normal user. Root is requested per-step via sudo only where needed
# (module install, clocklock helper). Verified on CachyOS/Arch; other distros
# should work for the driver build but package checks degrade to warnings.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER_VERSION=610.57.04
TREE="${OGKM_DIR:-$HOME/open-gpu-kernel-modules}"

if [ "$EUID" -eq 0 ]; then
    echo "[-] Run as a normal user, not root. Steps that need root use sudo." >&2
    exit 1
fi

msg()  { printf '\n=== %s ===\n' "$*"; }
warn() { printf '[!] %s\n' "$*"; }
note() { printf '[*] %s\n' "$*"; }
ok()   { printf '[+] %s\n' "$*"; }

ask() {  # ask "question" -> 0 if yes (default yes)
    local reply
    read -r -p "$1 [Y/n]: " reply
    [[ ! "$reply" =~ ^[Nn]$ ]]
}

patches_applied() {
    [ -f "$TREE/kernel-open/nvidia/os-pci.c" ] && \
        grep -q os_pci_is_thunderbolt_attached "$TREE/kernel-open/nvidia/os-pci.c"
}

tree_version() {
    grep -m1 -oE '[0-9]+\.[0-9]+\.[0-9]+' "$TREE/version.mk" 2>/dev/null || echo "unknown"
}

check_state() {
    msg "System state"
    echo "Kernel:            $(uname -r)"
    if [ -f "/lib/modules/$(uname -r)/build/Makefile" ]; then
        ok "Kernel headers present"
    else
        warn "Kernel headers MISSING for $(uname -r) (install your distro's headers package)"
    fi
    if grep -qi clang /proc/version; then
        note "Kernel built with Clang -> driver build will use LLVM=1 CC=clang LD=ld.lld"
    fi
    if command -v pacman >/dev/null 2>&1; then
        echo "nvidia-utils:      $(pacman -Q nvidia-utils 2>/dev/null || echo 'not installed')"
        if pacman -Q nvidia-open-dkms >/dev/null 2>&1; then
            warn "nvidia-open-dkms is installed: its UNPATCHED module in updates/dkms/ SHADOWS a manually built one. Remove it."
        fi
    fi
    if ls "/lib/modules/$(uname -r)/updates/dkms/nvidia.ko"* >/dev/null 2>&1; then
        warn "DKMS nvidia module present for this kernel -- it will shadow the patched build"
    fi
    if modinfo nvidia >/dev/null 2>&1; then
        echo "Installed module:  $(modinfo -F version nvidia 2>/dev/null) (vermagic $(modinfo -F vermagic nvidia 2>/dev/null | awk '{print $1}'))"
    else
        note "No nvidia module installed for the running kernel"
    fi
    if [ -d "$TREE" ]; then
        echo "Driver tree:       $TREE (version $(tree_version))"
        if patches_applied; then ok "Patches: applied in tree"; else note "Patches: NOT applied in tree"; fi
    else
        note "Driver tree not found at $TREE (set OGKM_DIR=... to override)"
    fi
    if [ -x "$HOME/.local/bin/blackwell-egpu-status" ]; then ok "Widget backend installed"; else note "Widget backend not installed"; fi
    if [ -d "$HOME/.local/share/plasma/plasmoids/com.github.blackwellegpu.status" ]; then ok "Widget applet installed"; else note "Widget applet not installed"; fi
    if [ -x /usr/local/bin/blackwell-egpu-clocklock ]; then ok "Clock-lock helper installed"; else note "Clock-lock helper not installed"; fi
    if [ -f /etc/blackwell-egpu/clocklock-pinned ]; then
        ok "Clock lock is PINNED (applies at boot/attach)"
    fi
}

install_patches() {
    msg "1/3 Patched driver modules ($DRIVER_VERSION)"

    if [ ! -f "/lib/modules/$(uname -r)/build/Makefile" ]; then
        warn "Kernel headers missing for $(uname -r). Install them first (Arch: linux-<flavor>-headers)."
        return 1
    fi

    if command -v pacman >/dev/null 2>&1; then
        local UTILS
        UTILS=$(pacman -Q nvidia-utils 2>/dev/null | awk '{print $2}' | cut -d- -f1 || true)
        if [ -n "$UTILS" ] && [ "$UTILS" != "$DRIVER_VERSION" ]; then
            warn "nvidia-utils is $UTILS but the patches target $DRIVER_VERSION."
            warn "Kernel modules and userspace MUST match. Pin nvidia-utils or port the patches."
            ask "Continue anyway?" || return 1
        fi
        if pacman -Q nvidia-open-dkms >/dev/null 2>&1; then
            warn "nvidia-open-dkms is installed and will SHADOW the patched module. Remove it first."
            return 1
        fi
    fi

    if [ ! -d "$TREE/.git" ]; then
        note "Driver source not found at $TREE"
        ask "Clone NVIDIA/open-gpu-kernel-modules @ $DRIVER_VERSION there now (~300 MB download)?" || return 1
        git clone --branch "$DRIVER_VERSION" --depth 1 \
            https://github.com/NVIDIA/open-gpu-kernel-modules "$TREE"
    fi

    cd "$TREE"
    local TV
    TV=$(tree_version)
    if [ "$TV" != "$DRIVER_VERSION" ] && ! patches_applied; then
        warn "Tree at $TREE reports version $TV, patches target $DRIVER_VERSION."
        warn "Check out the matching tag first: cd $TREE && git checkout $DRIVER_VERSION"
        return 1
    fi

    if patches_applied; then
        ok "Patches already present in tree; skipping apply."
    else
        if [ -n "$(git status --porcelain)" ]; then
            warn "Tree has uncommitted changes; refusing to apply patches on top. Clean it first."
            return 1
        fi
        note "Dry-running patch set..."
        local p
        for p in "$REPO_DIR"/patches/*.patch; do
            git apply --check "$p" || { warn "Patch does not apply: $p -- stopping (no changes made)"; return 1; }
        done
        for p in "$REPO_DIR"/patches/*.patch; do
            git apply "$p"
            ok "Applied $(basename "$p")"
        done
    fi

    local FLAGS=""
    grep -qi clang /proc/version && FLAGS="LLVM=1 CC=clang LD=ld.lld"
    note "Building modules ($FLAGS)... this takes a few minutes"
    # shellcheck disable=SC2086
    make -j"$(nproc)" modules $FLAGS

    note "Installing modules (sudo)..."
    sudo make modules_install -j"$(nproc)"
    sudo depmod -a

    local VM
    VM=$(modinfo -F vermagic nvidia 2>/dev/null | awk '{print $1}')
    if [ "$VM" = "$(uname -r)" ]; then
        ok "Installed: nvidia $(modinfo -F version nvidia) for $VM"
    else
        warn "vermagic ($VM) does not match running kernel ($(uname -r)) -- something is off"
        return 1
    fi

    if [ ! -f /etc/modprobe.d/99-nvidia-egpu.conf ]; then
        echo ""
        note "Suggested /etc/modprobe.d/99-nvidia-egpu.conf (see patches/README.md):"
        echo "    options nvidia NVreg_DynamicPowerManagement=0"
        echo "    options nvidia NVreg_EnableResizableBar=0"
        echo "    options nvidia NVreg_InitializeSystemMemoryAllocations=0"
        echo "    softdep nvidia post: nvidia-uvm"
        if ask "Install it now (sudo)?"; then
            printf '%s\n' \
                "options nvidia NVreg_DynamicPowerManagement=0" \
                "options nvidia NVreg_EnableResizableBar=0" \
                "options nvidia NVreg_InitializeSystemMemoryAllocations=0" \
                "softdep nvidia post: nvidia-uvm" \
                | sudo tee /etc/modprobe.d/99-nvidia-egpu.conf >/dev/null
            ok "Wrote /etc/modprobe.d/99-nvidia-egpu.conf"
        fi
    fi

    ok "Driver done. Load with: sudo modprobe nvidia_drm   (or reboot)"
    note "Verify: sudo dmesg | grep -i 'external GPU'  -> expect 'external GPU detected (thunderbolt-attached=yes...)'"
    note "Rebuild is required after every kernel update (modules are not DKMS-managed)."
}

install_widget() {
    msg "2/3 Plasma 6 status widget (user-level)"
    bash "$REPO_DIR/widget/install.sh"
}

install_clocklock() {
    msg "3/3 Clock-lock helper (root; sudoers scoped to 4 literal commands)"
    sudo bash "$REPO_DIR/widget/clocklock/install-clocklock.sh"
}

case "${1:-}" in
    --check)
        check_state
        ;;
    --patches)
        install_patches
        ;;
    --widget)
        install_widget
        ;;
    --clocklock)
        install_clocklock
        ;;
    --all)
        install_patches
        install_widget
        install_clocklock
        ;;
    "")
        check_state
        echo ""
        ask "Install patched driver modules?" && install_patches || true
        ask "Install the Plasma 6 status widget?" && install_widget || true
        ask "Install the clock-lock helper (widget toggles + boot pin)?" && install_clocklock || true
        ok "Done."
        ;;
    *)
        sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
