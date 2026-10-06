# pacman hooks

## zy-amdgpu-frl-rebuild (Oct 6, 2026) — automatic rebuild of the patched amdgpu

This handles the *other* out-of-tree module in this repo: the patched amdgpu built by
`tools/amdgpu-frl-module/build.sh`. The override lives in `/usr/lib/modules/<ver>/updates/amdgpu-frl-lt/`.
A kernel update brings a new `<ver>`, the override silently stops applying, and the stock driver comes
back with no HDMI FRL loss-of-lock recovery. The TV then stays dark at the login screen and after
wakes. This happened on 7.2.6 -> 7.2.7 (Sep 23), 7.2.8-1 -> 7.2.8-2 (Oct 1) and 7.2.8-2 -> 7.2.9-1
(Oct 3).

    sudo bash install-amdgpu-frl-rebuild.sh            # install (builds as $SUDO_USER)
    sudo bash install-amdgpu-frl-rebuild.sh --remove   # remove
    sudo /usr/local/bin/amdgpu-frl-rebuild             # run by hand: covers any kernel missing it

**When it runs:** PostTransaction on `linux-cachyos` / `-headers`. It covers every installed kernel that
has headers but no override, skipping `*-lts`.

**What it does for each such kernel:**

1. **Build, as the user:** `build.sh --build-only` with `KVER` set to the new kernel. This fetches the
   CachyOS source if it is missing, so it needs the network and a few minutes. It runs as the user
   because makepkg refuses root and `~/kbuild` belongs to the user.
2. **Install, as root:** `build.sh --install-only`, which installs the module, runs depmod, checks that
   amdgpu resolves to the override, and rebuilds the initramfs.
3. **Clean up:** `build.sh --cleanup` drops what kernels no longer installed left behind.

**Ordering:** the name starts `zy-` so it runs after `90-mkinitcpio-install` and `nvidia-egpu-rebuild`,
which makes the initramfs it builds the final one.

**Failures:** it never fails the transaction. If a build fails (offline, or a patch that needs
rebasing), it prints which kernels are left stock, the tail of `/var/log/amdgpu-frl-rebuild.log`, and the
command to run after rebooting.

**Config:** `/etc/amdgpu-frl-rebuild.conf` (`BUILD_USER`, `REPO`), written by the installer.

## amdgpu-frl-override-check (Sep 23, 2026) — superseded

This was the warning-only predecessor: it printed the affected kernels and the commands to run, and
built nothing. **It was never actually installed on this machine** (found Oct 6), which is why the
7.2.8-2 and 7.2.9-1 updates gave no warning. `install-amdgpu-frl-rebuild.sh` removes its two files if
they are present. The scripts stay here for reference:

    sudo bash install-amdgpu-frl-check.sh            # install
    /usr/local/bin/amdgpu-frl-override-check         # run by hand any time; changes nothing
