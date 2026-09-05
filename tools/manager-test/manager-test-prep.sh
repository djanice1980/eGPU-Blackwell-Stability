#!/usr/bin/env bash
# Prepare a snapshot-protected test of DamianKA1993/blackwell-egpu-manager on the live
# CachyOS install (no reinstall). Run as your normal user; it uses sudo per step.
#
#   bash ~/Downloads/manager-test-prep.sh
#
# What it does:
#   1. Creates a snapper snapshot of / and publishes it to the Limine boot menu
#      (limine-snapper-sync), so a broken state is one reboot away from undone.
#   2. Moves OUR two eGPU config files aside (not deleted) so the manager is tested
#      without them:  /etc/modprobe.d/zz-nvidia-egpu.conf
#                     /etc/udev/rules.d/99-usb4-tunnel-ports-awake.rules
#      Copies land in ~/egpu-manager-test-backup/ ; manager-test-restore.sh puts them back.
#   3. Prints the install + test steps.
# It does NOT run Damian's installer for you and does NOT touch the kernel cmdline or
# the patched nvidia modules (those deviations are disclosed in the report instead).
set -euo pipefail
[ "$EUID" -ne 0 ] || { echo "Run as your normal user, not root."; exit 1; }

BACKUP="$HOME/egpu-manager-test-backup"
MODPROBE=/etc/modprobe.d/zz-nvidia-egpu.conf
UDEVPIN=/etc/udev/rules.d/99-usb4-tunnel-ports-awake.rules
REPO="$HOME/Downloads/blackwell-egpu-manager"

echo "== 0. sanity"
[ -x "$REPO/install.sh" ] || { echo "manager clone missing at $REPO"; exit 1; }
git -C "$REPO" describe --tags --always
sudo -v

echo "== 1. snapper snapshot of / (root config) + Limine boot-menu sync"
NUM=$(sudo snapper -c root create --type single --cleanup-algorithm number \
      --description "pre blackwell-egpu-manager test $(date +%F)" --print-number)
echo "snapshot #$NUM created"
sudo limine-snapper-sync >/dev/null 2>&1 || echo "  (limine-snapper-sync returned non-zero; check 'sudo limine-snapper-sync' output manually)"
if sudo grep -qE "#?$NUM\b|Snapshot.*$NUM" /boot/limine.conf 2>/dev/null; then
    echo "  snapshot #$NUM is listed in /boot/limine.conf (bootable from the Limine 'Snapshots' menu)"
else
    echo "  WARNING: could not find snapshot #$NUM in /boot/limine.conf; run 'sudo limine-snapper-sync' and check the Snapshots menu before proceeding"
fi

echo "== 2. move our eGPU config aside (restore with manager-test-restore.sh)"
mkdir -p "$BACKUP"
for f in "$MODPROBE" "$UDEVPIN"; do
    if [ -e "$f" ]; then
        sudo cp -a "$f" "$BACKUP/"          # keep a copy first
        sudo mv "$f" "$BACKUP/$(basename "$f").moved"
        echo "  moved $f -> $BACKUP/"
    else
        echo "  $f not present (already moved?)"
    fi
done
sudo udevadm control --reload-rules
ls -la "$BACKUP"

cat <<'EOF'

== 3. next steps (manual, in this order)
  a) Install the manager exactly as Damian asks (answer Y to udev rules, 1 for the
     Plasma applet, N to reboot-now):
        cd ~/Downloads/blackwell-egpu-manager && ./install.sh
  b) Close the Claude desktop app and anything using the 5070 Ti before Mode 6 tests
     (they hold /dev/nvidiactl; see the soft-loss memory).
  c) Reboot with the enclosure ON and the cable attached (cold-boot case). At the desktop:
        bash ~/Downloads/manager-test-log.sh boot
     Expect: NO 61:/62: Barlow Ridge bridges in lspci and no GPU (his udev rule removed
     them), applet in Mode 2 "Standby".
  d) Click Mode 3 in his applet (or: sudo blackwell-egpu set 3), then:
        bash ~/Downloads/manager-test-log.sh mode3
     Expect: bridges + GPU back, LnkSta 16 GT/s x4, nvidia modules loaded, clocks locked.
  e) Play for 30+ min, then:  bash ~/Downloads/manager-test-log.sh after-game
  f) Mode 6 (safe detach) from Mode 3 — this is the path that froze both displays for us
     on 2026-09-02, so have Meta+Shift+D ready:  bash ~/Downloads/manager-test-log.sh mode6
  g) Repeat c)-d) two more times for a 3/3 cold-boot count.
  NEVER press Mode 4 (eGPU-only): it PCI-removes the Radeon 8060S that drives the Z13 panel.

== rollback if anything is wedged
  reboot -> Limine menu -> Snapshots -> the "pre blackwell-egpu-manager test" entry
  (then 'sudo limine-snapper-restore' or Btrfs Assistant to make it permanent), or just
  run manager-test-restore.sh + ./uninstall.sh if the system is still usable.
EOF
