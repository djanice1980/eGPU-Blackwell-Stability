#!/usr/bin/env bash
# Build ONLY the amdgpu module, with the HDMI FRL link-training patch
# (kernel-patches/0001-*.patch) applied, against the RUNNING kernel's installed headers, and
# install it as a module override that a single directory delete reverts.
#
# Why this shape: the fix is one line in drivers/gpu/drm/amd/display/dc/link/protocols/
# link_hdmi_frl.c. Rebuilding the whole kernel package would give a custom kernel that the next
# `pacman -Syu` overwrites. Instead kbuild is run with srctree = the full kernel source and
# objtree (O=) = a writable copy of the installed headers tree, which already holds the exact
# .config, generated headers, host tools and Module.symvers of the running kernel, so no kernel
# prepare step and no `bc` are needed. (A plain external-module build against the headers tree
# fails: amdgpu's tracepoint headers are included relative to the headers tree, which does not
# ship them.) The result goes to /usr/lib/modules/<ver>/updates/, which depmod searches before
# kernel/, so the stock amdgpu.ko.zst stays on disk untouched. amdgpu is in the initramfs
# (early KMS), so the initramfs is rebuilt too. A kernel package update installs a new <ver>
# directory, so the override simply stops applying: nothing to undo.
#
# One-off prerequisite — the CachyOS kernel source for the running version, from their
# PKGBUILD (prepare() may fail at `bc`; that is fine, only the extracted tree is needed):
#     mkdir -p ~/kbuild && cd ~/kbuild && git clone https://github.com/CachyOS/linux-cachyos.git
#     cd linux-cachyos/linux-cachyos && git log --oneline -1 -- PKGBUILD   # must be your version
#     makepkg --nobuild --nodeps --noconfirm --skippgpcheck
#   The tree lands in src/cachyos-<ver>-<rel>/ (CachyOS ships a pre-patched tarball).
#
#   bash build.sh                 build, then install (asks for sudo at the install step)
#   bash build.sh --build-only    stop after the build; module left in the source tree
#   bash build.sh --remove        remove the override, depmod, rebuild initramfs
# Reboot after install or remove: the running amdgpu cannot be unloaded under a live desktop.
set -euo pipefail
KVER="${KVER:-$(uname -r)}"
BUILD=/usr/lib/modules/$KVER/build
SRC="${SRC:-$(ls -d ~/kbuild/linux-cachyos/linux-cachyos/src/cachyos-* 2>/dev/null | head -1)}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PATCH="$(ls "$REPO"/kernel-patches/0001-drm-amd-display-*.patch | head -1)"
DEST=/usr/lib/modules/$KVER/updates/amdgpu-frl-lt
FRL=drivers/gpu/drm/amd/display/dc/link/protocols/link_hdmi_frl.c
say() { echo "[amdgpu-frl] $*"; }
rebuild_initramfs() { if command -v limine-mkinitcpio >/dev/null 2>&1; then sudo limine-mkinitcpio; else sudo mkinitcpio -P; fi; }

if [ "${1:-}" = "--remove" ]; then
    sudo rm -rf "$DEST"; sudo depmod "$KVER"
    say "override removed; amdgpu now resolves to $(modinfo -k "$KVER" -n amdgpu)"
    rebuild_initramfs
    say "reboot to run the stock module again"; exit 0
fi

[ -d "$SRC" ] || { say "kernel source not found (see the prerequisite in this script's header)"; exit 1; }
[ -f "$BUILD/Module.symvers" ] || { say "headers for $KVER missing (linux-cachyos-headers)"; exit 1; }
[ -f "$PATCH" ] || { say "patch not found under $REPO/kernel-patches"; exit 1; }
SRCREL=$(sed -nE 's/^#define UTS_RELEASE "(.*)"/\1/p' "$BUILD/include/generated/utsrelease.h")
[ "$SRCREL" = "$KVER" ] || { say "headers say $SRCREL, running kernel is $KVER"; exit 1; }
case "$SRC" in *"${KVER%%-*}"*) ;; *) say "source dir $SRC does not look like kernel ${KVER%%-*}"; exit 1;; esac

cd "$SRC"
say "source: $SRC"
if patch -p1 -N --dry-run -s < "$PATCH" >/dev/null 2>&1; then
    patch -p1 -N -s < "$PATCH"; say "applied $(basename "$PATCH")"
elif patch -p1 -R --dry-run -s < "$PATCH" >/dev/null 2>&1; then
    say "patch already applied"
else
    say "patch does not apply to this source"; exit 1
fi
grep -q "max_polls = 155;" "$FRL" || { say "patched line not found in $FRL"; exit 1; }

OBJ=$HOME/kbuild/obj-$KVER
if [ ! -f "$OBJ/Module.symvers" ]; then
    say "copying the headers tree to a writable object tree: $OBJ"
    rm -rf "$OBJ"; cp -a "$(readlink -f "$BUILD")" "$OBJ"
fi
say "building drivers/gpu/drm/amd/amdgpu (srctree=$SRC, O=$OBJ) with clang (several minutes)..."
LOG=$HOME/kbuild/amdgpu-build.log
make O="$OBJ" M=drivers/gpu/drm/amd/amdgpu LLVM=1 LLVM_IAS=1 -j"$(nproc)" modules > "$LOG" 2>&1 \
    || { say "build failed -- see $LOG"; grep -iE "error" "$LOG" | head; exit 1; }
KO=$OBJ/drivers/gpu/drm/amd/amdgpu/amdgpu.ko
[ -f "$KO" ] || KO=$SRC/drivers/gpu/drm/amd/amdgpu/amdgpu.ko
[ -f "$KO" ] || { say "build produced no amdgpu.ko"; exit 1; }
VM=$(modinfo -F vermagic "$KO")
[ "${VM%% *}" = "$KVER" ] || { say "vermagic '$VM' does not match $KVER"; exit 1; }
# the packaged module is installed with INSTALL_MOD_STRIP=1; the fresh one carries ~650 MB of DWARF
STRIPPED=$HOME/kbuild/amdgpu-frl-lt-$KVER.ko
cp "$KO" "$STRIPPED" && llvm-strip --strip-debug "$STRIPPED"
say "built: $(du -h "$STRIPPED" | cut -f1) after strip-debug (stock is $(du -h "$(modinfo -k "$KVER" -n amdgpu)" | cut -f1) compressed)  vermagic='$VM'"

[ "${1:-}" = "--build-only" ] && { say "--build-only: module at $STRIPPED"; exit 0; }

sudo install -D -m 644 "$STRIPPED" "$DEST/amdgpu.ko"
sudo depmod "$KVER"
NOW=$(modinfo -k "$KVER" -n amdgpu)
case "$NOW" in "$DEST"/*) say "override active: $NOW";; *) say "depmod still resolves amdgpu to $NOW -- not installed as expected"; exit 1;; esac
rebuild_initramfs
say "done. REBOOT, then: bash $REPO/tools/hdmi-frl-lt-capture.sh at 4K120 and look for PASSED on try 1."
say "revert: bash $REPO/tools/amdgpu-frl-module/build.sh --remove, then reboot."
