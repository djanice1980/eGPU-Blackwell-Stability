# eGPU patches for NVIDIA open-gpu-kernel-modules 610.57.04

Six patches that make Thunderbolt/USB4 external GPUs (eGPUs) usable with NVIDIA's open
kernel modules, applied against driver **610.57.04**. Verified on:

- ASUS ROG Flow Z13 GZ302EA (AMD Strix Halo, integrated AMD USB4 host)
- Razer Core X V2 enclosure (Intel JHL9480 / Barlow Ridge TB5)
- RTX 5070 Ti (GB203, Blackwell)
- CachyOS, kernel 7.2.0 (Clang/LLVM-built)

Applied together: `37 files changed, 1330 insertions(+), 132 deletions(-)`.

## Attribution

Patches 01–05 are the unmodified `patches/base/` set from **apnex/nvidia-driver-injector**
(https://github.com/apnex/nvidia-driver-injector), written against 595.71.05 — they apply
cleanly to 610.57.04 as-is. All design credit to apnex; see that repo and
NVIDIA/open-gpu-kernel-modules issue **#979** for the full investigation.

Patch 06 is apnex's `C5-crash-safety.patch` **rebased for 610.57.04**: the original fails
on 610 due to context drift only (610 added `is_cxl_dev` to `nv_state_t` in both `nv.h`
copies, and a new include in `resserv/src/rs_server.c`). The rebase relocates those hunks;
no functional changes. Apply it **after** 01–05 — it depends on them.

apnex's own framing applies: this is **a mitigation, not a fix**. The underlying GSP
firmware limitations are NVIDIA's to solve.

## What each patch does

| # | Patch | Effect |
|---|---|---|
| 01 | E1-egpu-detection | Rewrites `RmCheckForExternalGpu()` to use the kernel's own Thunderbolt classification (`os_pci_is_thunderbolt_attached()`) instead of walking the bus for Intel TB3-era bridge IDs. Fixes non-detection on TB4/TB5/USB4 hosts (Intel Barlow Ridge, AMD USB4). No registry key needed — detection is automatic. Success line in dmesg: `nvidia XXXX:XX:00.0: external GPU detected (thunderbolt-attached=yes, external/untrusted=yes)` |
| 02 | C2-aer-internal-unmask | Clears the AER Uncorrectable Internal Error mask at probe so real PCIe errors reach kernel handlers instead of being demoted. Logs `AER: unmasked Uncorrectable Internal Error at probe` on attach — expected. |
| 03 | C3-gpu-lost-retry | Retries `NV_PMC_BOOT_0` 10× at 100 µs before declaring the GPU lost. Stock driver commits to permanent `PDB_PROP_GPU_IS_LOST` on a **single** `0xFFFFFFFF` read — routine transient noise on a tunneled link. Log on save: `GPU-lost check: transient PCIe read recovered after N retries`. |
| 04 | C4-err-handlers-scaffold | Registers `pci_error_handlers` (upstream leaves them absent). |
| 05 | C6-cond-acquire-rwlock-fix | Fixes an inverted conditional-acquire rwlock primitive. |
| 06 | C5-crash-safety (610 rebase) | Dead-bus guards across ~36 files so a genuinely lost GPU is contained instead of cascading (repeated failed RPC/dump calls against a dead bus). Adds `rm_cleanup_gpu_lost_state()` + `nv-gpu-lost.h`. Loss signature becomes a single line: `cleanupGpuLostStateAtomic: GPU N lost via detector_class=N`. Includes DRM/modeset-layer guards. Known cosmetic gap on 610: two `nvidia_dev_put` refcount WARNs can fire in `nvkms_close_gpu`/`nvidia_close` teardown after a loss. |

## Prerequisites

- `open-gpu-kernel-modules` source at tag **610.57.04** (`git checkout 610.57.04`)
- Userspace driver (nvidia-utils or equivalent) at the **same version**
- Kernel headers for your running kernel
- If your kernel is built with Clang (CachyOS, some others): LLVM toolchain

## Apply

```sh
cd open-gpu-kernel-modules
git checkout 610.57.04
for p in /path/to/patches/*.patch; do git apply --check "$p" || echo "FAIL: $p"; done  # dry run
for p in /path/to/patches/*.patch; do git apply "$p"; done                             # apply in filename order
git diff --stat | tail -1   # expect: 36 files, 1193 insertions (+ the new nv-gpu-lost.h = 37/1330 once staged)
```

Numbered filenames encode the required order. If any patch fails mid-sequence, stop —
later patches depend on earlier ones.

## Build & install

GCC-built kernels:
```sh
make clean && make -j$(nproc) modules && sudo make modules_install -j$(nproc) && sudo depmod -a
```

Clang/LLVM-built kernels (CachyOS etc.) — **required or the link fails**:
```sh
make clean && make -j$(nproc) modules LLVM=1 CC=clang LD=ld.lld && \
  sudo make modules_install -j$(nproc) && sudo depmod -a
```

Notes:
- `sign-file` SSL errors during install are cosmetic (no signing key present) unless you
  enforce Secure Boot with your own MOK.
- objtool `'naked' return` / retpoline warnings are pre-existing on every open-modules
  build; not introduced by these patches.
- Verify: `modinfo nvidia | grep vermagic` must match `uname -r`.
- These modules install to `kernel/drivers/video/` and are **not DKMS-managed** — rebuild
  after every kernel update. If a distro `nvidia-open-dkms` package is installed, its
  unpatched module in `updates/dkms/` **shadows yours** — remove it.

## Suggested module options

`/etc/modprobe.d/99-nvidia-egpu.conf` (the `99-` prefix matters — distro defaults like
`NVreg_DynamicPowerManagement=0x02` must not win):
```
options nvidia NVreg_DynamicPowerManagement=0
options nvidia NVreg_EnableResizableBar=0
options nvidia NVreg_InitializeSystemMemoryAllocations=0
```

Platform-side settings that mattered on the verified system (yours may differ):
kernel cmdline `pcie_port_pm=off` (without it the tunnel link drops ~1 s after module
load), `pcie_aspm.policy=performance`, `thunderbolt.clx=0`.

**Do not use `pcie_aspm=off` or `pcie_ports=native` on AMD USB4 hosts.** Both override the
platform's `_OSC` arrangement and break MSI-X allocation for the tunneled GPU:
`Failed to enable MSI-X` → `RmInitAdapter failed! (0x22:0x38:859)` → an IOMMU page-fault
storm as the GPU DMAs without interrupts. Verified on the reference system.

## Verify

```sh
sudo dmesg | grep -iE 'external GPU|NVRM|Xid'
nvidia-smi
```

Success: the `external GPU detected` line, no Xid, card visible. On any later GPU loss,
the C5 signature is one `detector_class` line and a contained teardown — not an RPC
failure cascade.

## Known limitations (verified on the reference system)

- **Driving a Wayland/X desktop from the eGPU does not work** on Blackwell over a tunnel
  (sparkles → blank → bus drop under display load). Compute, CUDA, and PRIME render
  offload are stable — including sustained 200 W load and multi-hour sessions with
  `nvidia_drm` loaded, provided the card was present at boot/attach and the compositor
  merely holds (not renders through) it. The failure is inside GSP firmware; no
  kernel-side patch fixes it. Maximum-stability alternative: blacklist
  `nvidia_drm`/`nvidia_modeset` (compute-only, apnex's configuration) and point Vulkan
  present-capable apps at your iGPU ICD via `VK_DRIVER_FILES`.
- `NVreg_EnableGpuFirmware=0` (seen in older eGPU guides) is a **no-op on the open
  modules** — they always run GSP, and Blackwell requires the open modules. Don't chase it.
- Cold-boot USB4 tunnel establishment failures on AMD hosts (device absent until cable
  replug) are a platform/kernel issue **below** this driver — these patches neither cause
  nor fix that. See the in-flight kernel work: "thunderbolt: Fix PCIe device enumeration
  with delayed rescan".

## Re-applying after driver version bumps

When `nvidia-utils` moves past 610.57.04, check out the matching tag and retry the set.
Patches 01–05 have survived 595→610 unchanged; expect 06 to need a fresh rebase whenever
NVIDIA touches its context lines (the 610 rebase took two relocated hunks — it's drift,
not surgery).

## License

GPL-2.0, inherited from apnex/nvidia-driver-injector and matching the GPL-2.0 leg of the
NVIDIA open kernel modules' dual MIT/GPL-2.0 license. See LICENSE.
