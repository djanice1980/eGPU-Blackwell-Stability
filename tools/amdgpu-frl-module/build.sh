#!/usr/bin/env bash
# Build ONLY the amdgpu module, with every numbered patch in kernel-patches/ applied, against
# the RUNNING kernel's installed headers, and install it as a module override that a single
# directory delete reverts.
#
# The source tree is stamped with a hash of the patch set. If the stamp matches, nothing is
# touched; otherwise every file the series touches is restored from the pristine CachyOS tarball
# and the whole series is reapplied. So this is idempotent and self-healing from any tree state --
# half-patched, hand-edited, or patched with an older version of the series.
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
#   Repeat those two commands after every kernel update: the override lives under
#   /usr/lib/modules/<ver>/ and silently stops applying when <ver> changes, so the stock driver
#   comes back until this is rebuilt for the new kernel.
#
#   bash build.sh                 build, then install (asks for sudo at the install step)
#   bash build.sh --build-only    stop after the build; module left in the source tree
#   bash build.sh --remove        remove the override, depmod, rebuild initramfs
# Reboot after install or remove: the running amdgpu cannot be unloaded under a live desktop.
set -euo pipefail
KVER="${KVER:-$(uname -r)}"
BUILD=/usr/lib/modules/$KVER/build
# the source dir for THIS kernel: 7.2.7-1-cachyos -> src/cachyos-7.2.7-1. Never glob blindly: after a
# kernel update several versions sit side by side and the wrong one builds a module that will not load.
SRCROOT=~/kbuild/linux-cachyos/linux-cachyos/src
SRC="${SRC:-$SRCROOT/cachyos-${KVER%-cachyos}}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# every numbered patch in kernel-patches/, in order; *.amd-staging-drm-next.patch is the
# upstream rebase of 0001 and must NOT be applied to this tree
mapfile -t PATCHES < <(ls "$REPO"/kernel-patches/0*.patch 2>/dev/null | grep -v "amd-staging-drm-next" | sort)
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

[ -d "$SRC" ] || { say "no kernel source for $KVER at $SRC"; say "refresh it: cd ~/kbuild/linux-cachyos && git pull && cd linux-cachyos && makepkg --nobuild --nodeps --noconfirm --skippgpcheck"; exit 1; }
[ -f "$BUILD/Module.symvers" ] || { say "headers for $KVER missing (linux-cachyos-headers)"; exit 1; }
[ "${#PATCHES[@]}" -gt 0 ] || { say "no patches found under $REPO/kernel-patches"; exit 1; }
SRCREL=$(sed -nE 's/^#define UTS_RELEASE "(.*)"/\1/p' "$BUILD/include/generated/utsrelease.h")
[ "$SRCREL" = "$KVER" ] || { say "headers say $SRCREL, running kernel is $KVER"; exit 1; }
case "$SRC" in *"${KVER%-cachyos}"*) ;; *) say "source dir $SRC does not match kernel ${KVER%-cachyos}"; exit 1;; esac

cd "$SRC"
say "source: $SRC"

# No guessing about whether a patch is already applied -- three separate attempts at that
# (reverse dry-run, then a content marker) each broke on a patch that touches two files or that
# edits a line an earlier patch added. Instead: stamp the tree with a hash of the patch set. If
# the stamp matches, the tree is already exactly right and nothing is touched. If it does not,
# restore every file the series touches from the pristine CachyOS tarball and apply the whole
# series from scratch. Deterministic from any starting state, including a half-patched tree or
# one somebody edited by hand.
STAMP=$SRC/.egpu-frl-patch-stamp
WANT=$(sha256sum "${PATCHES[@]}" | sha256sum | cut -d' ' -f1)
if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$WANT" ]; then
    say "patch set unchanged and already applied (${#PATCHES[@]} patches)"
else
    TARBALL=$SRCROOT/cachyos-${KVER%-cachyos}.tar.gz
    [ -f "$TARBALL" ] || TARBALL=$(dirname "$SRCROOT")/cachyos-${KVER%-cachyos}.tar.gz
    [ -f "$TARBALL" ] || { say "pristine tarball for ${KVER%-cachyos} not found -- refresh the PKGBUILD checkout (see the header)"; exit 1; }
    TOP=$(basename "$TARBALL" .tar.gz)
    mapfile -t FILES < <(grep -h '^+++ b/' "${PATCHES[@]}" | sed 's|^+++ b/||' | sort -u)
    [ "${#FILES[@]}" -gt 0 ] || { say "the patch series names no files"; exit 1; }
    TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
    for f in "${FILES[@]}"; do
        tar xzf "$TARBALL" -C "$TMP" "$TOP/$f" 2>/dev/null || { say "$f is not in $TARBALL"; exit 1; }
        cp "$TMP/$TOP/$f" "$SRC/$f"
    done
    say "reset ${#FILES[@]} file(s) to pristine from $(basename "$TARBALL")"
    rm -f "$STAMP"
    for P in "${PATCHES[@]}"; do
        patch -p1 -N -s < "$P" || { say "FAILED to apply $(basename "$P") to a pristine tree -- the patch needs rebasing"; exit 1; }
        say "applied $(basename "$P")"
    done
    echo "$WANT" > "$STAMP"
fi
grep -q "max_polls = 155;" "$FRL" || { say "the 300 ms LT change is not in $FRL"; exit 1; }
grep -q "FRL WATCHDOG:" "$FRL" || { say "the watchdog diagnostics are not in $FRL"; exit 1; }

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
say "built: $(du -h "$STRIPPED" | cut -f1) after strip-debug  vermagic='$VM'  patches: ${#PATCHES[@]}"

[ "${1:-}" = "--build-only" ] && { say "--build-only: module at $STRIPPED"; exit 0; }

sudo install -D -m 644 "$STRIPPED" "$DEST/amdgpu.ko"
sudo depmod "$KVER"
NOW=$(modinfo -k "$KVER" -n amdgpu)
# compare real paths: modinfo reports /lib/modules/..., which is /usr/lib/modules/... on Arch
if [ "$(readlink -f "$NOW")" = "$(readlink -f "$DEST/amdgpu.ko")" ]; then
    say "override active: $NOW"
else
    say "depmod still resolves amdgpu to $NOW -- not installed as expected"; exit 1
fi
rebuild_initramfs
say "done. REBOOT, then: bash $REPO/tools/hdmi-frl-lt-capture.sh at 4K120 and look for PASSED on try 1."
say "revert: bash $REPO/tools/amdgpu-frl-module/build.sh --remove, then reboot."
