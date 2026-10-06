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
#   After that, a kernel update needs nothing but this script and a reboot: the override lives
#   under /usr/lib/modules/<ver>/ and silently stops applying when <ver> changes, and when the
#   source for the new <ver> is missing this script pulls the PKGBUILD and fetches it itself.
#
#   bash build.sh                 build, install, then clean up after kernels no longer installed
#   bash build.sh --build-only    stop after the build; module left in the source tree
#   bash build.sh --remove        remove the override, depmod, rebuild initramfs
#   bash build.sh --cleanup [--dry-run]   only the clean-up (see prune_old_kernels)
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

# Clean up after kernels that are no longer installed. Every kernel update leaves ~4 GB here
# (source tree + tarball + object tree) and a /usr/lib/modules/<ver> directory the kernel package no
# longer owns -- it survives because the out-of-tree modules put into it (this amdgpu override, the
# NVIDIA hook's modules) are not package files. A version is stale only when ALL of these hold:
#   - it looks like a mainline CachyOS kernel (7.2.8-1-cachyos; never -lts or anything else)
#   - it is not the running kernel and not the one being built now
#   - /usr/lib/modules/<ver>/vmlinuz is gone and no package owns /usr/lib/modules/<ver>
# ~/kbuild files are removed as the user; the /usr/lib/modules directory needs sudo.
prune_old_kernels() {
    local dry=${1:-} running v base kb=~/kbuild pkgdir=~/kbuild/linux-cachyos/linux-cachyos
    local -a cand=() stale=() paths=() keep=()
    running=$(uname -r)
    # source trees still in use: the running kernel's and the one being built, followed through the
    # symlink reuse_pkgrel_rebuild leaves (7.2.8-2 -> 7.2.8-1). Their tree and tarball are never
    # pruned, even when the version they are named after is gone.
    for v in "$running" "$KVER"; do
        [ -e "$pkgdir/src/cachyos-${v%-cachyos}" ] || continue
        base=$(basename "$(readlink -f "$pkgdir/src/cachyos-${v%-cachyos}")"); keep+=("${base#cachyos-}")
    done
    mapfile -t cand < <( {
        ls /usr/lib/modules 2>/dev/null
        ls -d "$kb"/obj-* 2>/dev/null | sed 's|.*/obj-||'
        ls -d "$pkgdir"/src/cachyos-* 2>/dev/null | grep -v '\.tar' | sed 's|.*/cachyos-||; s|$|-cachyos|'
    } | sort -u )
    for v in "${cand[@]}"; do
        [[ "$v" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?-[0-9]+-cachyos$ ]] || continue
        [ "$v" = "$running" ] && continue
        [ "$v" = "$KVER" ] && continue
        [ -f "/usr/lib/modules/$v/vmlinuz" ] && continue
        pacman -Qqo "/usr/lib/modules/$v" >/dev/null 2>&1 && continue
        stale+=("$v")
    done
    if [ "${#stale[@]}" -eq 0 ]; then say "clean-up: nothing left over from old kernels"; return 0; fi
    for v in "${stale[@]}"; do
        base=${v%-cachyos}
        if printf '%s\n' "${keep[@]}" | grep -qxF "$base"; then
            # the tree is reused by a newer pkgrel: drop only what belongs to the old kernel itself
            for f in "$kb/obj-$v" "$kb/amdgpu-frl-lt-$v.ko" "/usr/lib/modules/$v"; do
                [ -e "$f" ] || [ -L "$f" ] && paths+=("$f")
            done
            continue
        fi
        for f in "$pkgdir/src/cachyos-$base" "$kb/obj-$v" \
                 "$pkgdir/src/cachyos-$base.tar.gz" "$pkgdir/src/cachyos-$base.tar.gz.asc" \
                 "$pkgdir/cachyos-$base.tar.gz" "$pkgdir/cachyos-$base.tar.gz.asc" \
                 "$kb/amdgpu-frl-lt-$v.ko" "$kb/prepare-$base.log" "/usr/lib/modules/$v"; do
            [ -e "$f" ] || [ -L "$f" ] && paths+=("$f")
        done
    done
    say "clean-up: kernels no longer installed: ${stale[*]}"
    say "clean-up: $(du -shc "${paths[@]}" 2>/dev/null | tail -1 | cut -f1) in ${#paths[@]} path(s)"
    if [ "$dry" = "--dry-run" ]; then
        printf '    would remove %s\n' "${paths[@]}"
        return 0
    fi
    for f in "${paths[@]}"; do
        case "$f" in
            /usr/lib/modules/*) sudo rm -rf -- "$f" ;;
            *) rm -rf -- "$f" ;;
        esac
    done
    say "clean-up: done"
}

if [ "${1:-}" = "--cleanup" ]; then
    prune_old_kernels "${2:-}"
    exit 0
fi

if [ "${1:-}" = "--remove" ]; then
    sudo rm -rf "$DEST"; sudo depmod "$KVER"
    say "override removed; amdgpu now resolves to $(modinfo -k "$KVER" -n amdgpu)"
    rebuild_initramfs
    say "reboot to run the stock module again"; exit 0
fi

# After a kernel update the matching source is not here yet, so fetch it: pull the CachyOS
# PKGBUILD checkout and let `makepkg --nobuild` download and extract the pre-patched tarball for
# that version. Its prepare() then fails for lack of `bc`; that does not matter, only the extracted
# tree and the tarball are used. Refuses when upstream's PKGBUILD is not the running version (for
# example CachyOS has already moved on), rather than building from the wrong source.
fetch_source() {
    local checkout=~/kbuild/linux-cachyos pkgdir=~/kbuild/linux-cachyos/linux-cachyos want have log srcname
    want=${KVER%-cachyos}                                   # 7.2.8-1-cachyos -> 7.2.8-1
    log=~/kbuild/prepare-$want.log
    [ -d "$checkout/.git" ] || { say "no CachyOS PKGBUILD checkout at $checkout (see the header)"; exit 1; }
    say "no source for $want yet -- pulling the CachyOS PKGBUILD and fetching it (a few minutes)"
    git -C "$checkout" pull -q --ff-only || { say "git pull in $checkout failed"; exit 1; }
    have="$(sed -n 's/^_major=//p' "$pkgdir/PKGBUILD" | head -1).$(sed -n 's/^_minor=//p' "$pkgdir/PKGBUILD" | head -1)-$(sed -n 's/^pkgrel=//p' "$pkgdir/PKGBUILD" | head -1)"
    # The tarball and tree are named by CachyOS's own tag revision (_tagrel), not by pkgrel:
    # linux-cachyos 7.2.9-1 unpacks src/cachyos-7.2.9-2 (_tagrel=2). For 7.2.8-1 the two matched.
    srcname="cachyos-$(sed -n 's/^_major=//p' "$pkgdir/PKGBUILD" | head -1).$(sed -n 's/^_minor=//p' "$pkgdir/PKGBUILD" | head -1)-$(sed -n 's/^_tagrel=//p' "$pkgdir/PKGBUILD" | head -1)"
    if [ "$have" != "$want" ]; then
        reuse_pkgrel_rebuild "$have" "$want" "$pkgdir" "$srcname" && return 0
        say "the CachyOS PKGBUILD is at $have but the running kernel is $want -- no matching source to fetch"; exit 1
    fi
    ( cd "$pkgdir" && makepkg --nobuild --nodeps --noconfirm --skippgpcheck ) > "$log" 2>&1 || true
    # link the kernel's name to the real (_tagrel-named) tree, as reuse_pkgrel_rebuild does
    if [ ! -e "$SRC" ] && [ "$SRCROOT/$srcname" != "$SRC" ] && [ -d "$SRCROOT/$srcname" ]; then
        ln -sfn "$srcname" "$SRC"
        say "CachyOS tag $srcname is the source for $want; linked"
    fi
    [ -d "$SRC" ] || { say "the fetch did not produce $SRC -- see $log"; exit 1; }
    say "source for $want ready"
}

# .config symbols that kconfig fills in by probing the compiler/assembler/linker. They change when
# the same kernel is rebuilt with a newer toolchain and say nothing about the source.
TOOLCHAIN_SYMS='^(# )?CONFIG_([A-Z0-9_]*VERSION[A-Z0-9_]*|CC_[A-Z0-9_]+|AS_[A-Z0-9_]+|LD_[A-Z0-9_]+|RUSTC_[A-Z0-9_]+|TOOLS_SUPPORT_[A-Z0-9_]+|WARN_CONTEXT_ANALYSIS)[= ]'

# CachyOS sometimes ships a new pkgrel of the same kernel without publishing a PKGBUILD change:
# 7.2.8-2 (Oct 1) is 7.2.8-1 rebuilt with clang 23.1.1 instead of 22.1.8, while the PKGBUILD still
# says pkgrel=1. The source is then the PKGBUILD's tree. Reuse it, but only when the running kernel's
# .config matches the one that tree was last built against apart from toolchain-probed symbols, by
# symlinking src/cachyos-<running> to it. Anything else still refuses: the wrong source builds a
# module that may load and misbehave.
reuse_pkgrel_rebuild() {
    local have=$1 want=$2 pkgdir=$3 srcname=$4 hsrc ref diffs ntool
    [ "${have%-*}" = "${want%-*}" ] || return 1             # different upstream version: no reuse
    [ -f "$BUILD/.config" ] || { say "headers for $KVER missing (linux-cachyos-headers)"; exit 1; }
    hsrc=$SRCROOT/$srcname
    if [ ! -d "$hsrc" ]; then
        ( cd "$pkgdir" && makepkg --nobuild --nodeps --noconfirm --skippgpcheck ) > ~/kbuild/prepare-$have.log 2>&1 || true
        [ -d "$hsrc" ] || { say "could not fetch the $have source to reuse -- see ~/kbuild/prepare-$have.log"; return 1; }
    fi
    ref=$(ls -t "$hsrc"/.egpu-kconfig-* 2>/dev/null | head -1 || true)
    [ -n "$ref" ] || ref=~/kbuild/obj-$have-cachyos/.config
    [ -f "$ref" ] || { say "no recorded .config for $have to compare with -- cannot show that $want is only a rebuild"; return 1; }
    diffs=$(diff <(grep -vE "$TOOLCHAIN_SYMS" "$ref") <(grep -vE "$TOOLCHAIN_SYMS" "$BUILD/.config") || true)
    if [ -n "$diffs" ]; then
        say "$want differs from $have in more than toolchain-probed .config symbols -- not reusing its source:"
        printf '%s\n' "$diffs" | head -20
        return 1
    fi
    ntool=$(diff "$ref" "$BUILD/.config" | grep -c '^[<>]' || true)
    say "$want is a rebuild of $have: .config identical apart from $ntool toolchain-probed line(s); reusing the $have source"
    ln -sfn "$srcname" "$SRCROOT/cachyos-$want"
}
[ -d "$SRC" ] || fetch_source
# the real source tree (src/cachyos-<ver> may be a symlink made by reuse_pkgrel_rebuild)
SRCVER=$(basename "$(readlink -f "$SRC")"); SRCVER=${SRCVER#cachyos-}
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
    TARBALL=$SRCROOT/cachyos-$SRCVER.tar.gz
    [ -f "$TARBALL" ] || TARBALL=$(dirname "$SRCROOT")/cachyos-$SRCVER.tar.gz
    [ -f "$TARBALL" ] || { say "pristine tarball for $SRCVER not found -- refresh the PKGBUILD checkout (see the header)"; exit 1; }
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
# makepkg's prepare() leaves .config and include/generated/ (utsrelease.h, autoconf.h) in the source
# tree. kbuild searches $(srctree)/include before $(objtree)/include, so those win over the running
# kernel's: the first 7.2.8-2 build (Oct 2) picked up 7.2.8-1's utsrelease.h and came out with
# vermagic 7.2.8-1 (and would have used 7.2.8-1's autoconf.h). Everything generated must come from the
# object tree, so keep the source tree free of it.
if [ -e "$SRC/.config" ] || [ -e "$SRC/include/generated" ] || [ -e "$SRC/include/config" ]; then
    say "source tree carries generated config/headers from makepkg's prepare() -- make mrproper"
    make -C "$SRC" mrproper > "$HOME/kbuild/mrproper.log" 2>&1 || { say "make mrproper failed -- see ~/kbuild/mrproper.log"; exit 1; }
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
# record the .config this source was built against, for reuse_pkgrel_rebuild's comparison next time
cp "$BUILD/.config" "$(readlink -f "$SRC")/.egpu-kconfig-$KVER"
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
prune_old_kernels
say "done. REBOOT, then: bash $REPO/tools/hdmi-frl-lt-capture.sh at 4K120 and look for PASSED on try 1."
say "revert: bash $REPO/tools/amdgpu-frl-module/build.sh --remove, then reboot."
