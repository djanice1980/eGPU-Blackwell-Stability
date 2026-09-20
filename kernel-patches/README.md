# Kernel patches (amdgpu)

Driver-side fixes found on this machine that are not (yet) upstream. Unlike `patches*/`
(NVIDIA open modules, applied by the pacman hook), these touch the in-tree amdgpu driver.

## 0001-drm-amd-display-Allow-300-ms-for-HDMI-FRL-link-train.patch (Sep 19, 2026)

One line in `drivers/gpu/drm/amd/display/dc/link/protocols/link_hdmi_frl.c`: the LTS:3
FLT_update budget goes from 105 polls (~210 ms) to 155 (~300 ms) at every FRL rate. Root cause
and the two captured trainings are in the runbook (Sep 19); the short form: the LG C2 needs
~180 ms after its LTP request to lock, and at 10G x4 (4K120 10-bit) its LTP request itself
comes ~45 ms after the rate write, so the total misses the single 210 ms budget that the driver
never restarts, while at 6G x4 (4K60) it just fits. AMD's own 7.4 change grants 300 ms only
for >= 16 Gbps.

- `*.patch` — for kernel 7.2.x (what CachyOS ships). Built and installed with
  `tools/amdgpu-frl-module/build.sh` as a module override, no custom kernel package.
  **Verified Sep 19 20:15**: 5/5 DPMS wakes at 4K120 10-bit RGB (10G x4) trained on the first
  try (logs in `docs/logs/frl-lt-4k120-fixed-*.log`), versus 1 in 2 failing before.
- `*.amd-staging-drm-next.patch` — the same change rebased on AMD's staging branch, which
  already carries the >= 16 Gbps conditional; this is the form to send to amd-gfx.
