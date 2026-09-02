# RTX 5070 Ti eGPU on CachyOS — Working Config & Rebuild Runbook (v2)

**System:** ASUS ROG Flow Z13 GZ302EA (Strix Halo) · CachyOS · kernel 7.2.0-1-cachyos
**eGPU:** RTX 5070 Ti (GB203, `10de:2c05`) in Razer Core X V2 (Intel JHL9480, `8086:5786`) over USB4
**Driver:** `open-gpu-kernel-modules` 610.57.04 + 6 patches (5 apnex base patches applied as-is, plus C5 rebased for 610)

Supersedes v1, which documented a hand-written `RmForceExternalGpu` patch. That patch is
obsolete — apnex's E1 replaces it with a proper fix.

---

## What works / what doesn't

**Works**
- eGPU auto-detected as external, no registry key needed
- Clean cold boot with enclosure attached, no manual rescan
- No Xid, no GSP heartbeat timeouts, no `RmInitAdapter failed`
- CUDA / compute
- PRIME render offload for individual apps
- **GL titles via PRIME offload — WITH clock locks held (adopted config, Aug 30).**
  Previously the ~75%-fatal workload; with the card pinned in P0 it has been stable in
  actual use: 8/8 clean launches, 1h+ sustained play, dmesg silent. Clock locking is
  now part of the standing stability configuration on this machine (pinned via the
  widget's clocklock helper), not an experiment.
- Monitor on the **laptop's** HDMI at 4K120 HDR 10-bit (via DSC), KWin on the AMD 8060S

**CURRENT CONFIGURATION (Aug 26, evening): full display stack loaded.**
`nvidia_drm` + `nvidia_modeset` load normally. `/etc/modprobe.d/99-nvidia-egpu.conf`
holds only the three NVreg options + `softdep nvidia post: nvidia-uvm`. No blacklists,
no EGL/Vulkan pins, no `KWIN_DRM_DEVICES`. Monitor on the laptop HDMI (AMD 8060S).

**The hard compute-only block was tried and REVERTED.** For the record, since it works
and may be wanted later: `blacklist nvidia_drm` + `blacklist nvidia_modeset` alone are
INSUFFICIENT — kwin_wayland reaches the card through the GLVND EGL side door
(nvidia-modprobe loads nvidia_modeset by explicit name, bypassing blacklists; confirmed
via `fuser` showing kwin holding /dev/nvidia-modeset). Hard enforcement needs
`install nvidia_modeset /bin/false` + `install nvidia_drm /bin/false`, plus
`~/.config/environment.d/` pins `VK_DRIVER_FILES=/usr/share/vulkan/icd.d/radeon_icd.json`
and `__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json`.
That configuration is the only one in which the display stack provably cannot touch the
card — but it also makes the card invisible to ALL Vulkan/GL apps (NVIDIA's Vulkan ICD
needs the blocked modeset device), which cost pcbview its GPU. Reverted for that reason.

**Evidence caveat on the "three triggers":** two of the three original kill triggers
(DPMS screen-wake; the ~10:53 soft-blacklist death) occurred while `pcie_ports=native`
was on the cmdline — the flag later proven to break MSI-X (see cmdline section). Those
two are contaminated evidence. Only the Sunday hotplug-probe Xid 79 and the pcbview
KPerfBoost crash are clean. A DPMS cycle on the clean cmdline was survived without
incident.

**API / phase stability rule (Aug 26, well supported):**
The failures are about *what phase of GPU work* happens over the tunnel, not which API:
- **Stable:** CUDA; Vulkan render-and-return (pcbview, hours); sustained GL once its
  context exists; SDDM rendering on the eGPU with a monitor plugged into it.
- **Fragile — state creation over the tunnel:** GL context creation via PRIME offload
  (`__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia`) kills the card
  **~75% of launches** (Wolfenstein: The New Order, id Tech 5, GL-only, via Proton).
  Signature: `tmrGetTimeEx_GH100: Consistently Bad TimeLo value ffffffff` →
  `_kgspIsHeartbeatTimedOut` → `_kgspRpcRecvPoll: LibOS heartbeat timed out` → Xid 154.
  Window never appears; card dies at context creation. Same class: KWin hotplug device
  probe, `KPerfBoost` perf-state transitions.
- **Degraded — scanout from the card:** monitor plugged into the 5070 Ti sparkles even
  at SDDM (real-time DSC scanout over the tunnel), then dies at session start when KWin
  applies the full display config. Meanwhile the same card renders a game and hands
  finished buffers to the AMD compositor with **no sparkles** — so bulk data over the
  tunnel is clean; it's the display engine's real-time path that isn't.
  Practical rule: **the card is reliable as a render device, unreliable as a display
  device.** Untested idea: a conservative output profile (1080p60, no HDR, no VRR) may
  survive session start — would distinguish bandwidth from GSP-side failure.
- Workarounds for GL titles: Zink (`MESA_LOADER_DRIVER_OVERRIDE=zink GALLIUM_DRIVER=zink`,
  drop `__GLX_VENDOR_LIBRARY_NAME`) routes GL through Vulkan — untested; or just run
  older GL titles on the 8060S, which handles them easily.

**Clock-lock mitigation for the GL-context-creation killer (Aug 30 — CONFIRMED, 8/8):**
Pinning the card in P0 so the fragile phase never crosses a P-state transition:
```
sudo nvidia-smi --lock-gpu-clocks=2000,3210 && sudo nvidia-smi --lock-memory-clocks=14001,14001
```
(3210/14001 = this card's max clocks; query with `--query-gpu=clocks.max.graphics,clocks.max.memory`.)
With locks held, Wolfenstein: TNO launched clean **8 times consecutively** plus over an
hour of sustained play — at the ~25% baseline survival rate, 8/8 is p≈1.5e-5 by chance.
dmesg fully silent throughout: no Xid, no heartbeat, and **no C3 transient-retry lines
either** — the failure window is not being entered, not merely survived, which is exactly
what the P-state-transition theory predicts. This upgrades the phase-stability rule: the
fragile phase is state creation *across a P-state transition*; hold the card in P0 and
GL context creation over the tunnel is safe. Cost: idle draw 10.6 W → 30.6 W (card held in P0, VRAM at full clock); load
behaviour unchanged. Locks do NOT persist across driver reload/reboot and die with any
GPU loss — reapply before each trial session (verify with `pstate` = P0). Do not enable
nvidia-persistenced to keep them — it blocks the `modprobe -r` the recovery procedure
needs. If the tally keeps holding, the ergonomic endgame is a per-game wrapper:
lock → launch → reset (`--reset-gpu-clocks --reset-memory-clocks`) on exit.

**Recovery procedure after ANY GPU death (learned the hard way, Aug 26):**
A host reboot alone does NOT reset the card (enclosure keeps it powered; wedged GSP
persists). An enclosure power-cycle alone does NOT clear the host (driver reuses stale
state → AMD-Vi IO_PAGE_FAULT storm at re-probe, repeating identical addresses).
BOTH sides must reset, in this order:
1. Unplug the TB cable FIRST (device off the bus).
2. THEN `sudo modprobe -r nvidia_uvm nvidia` — instant with the device gone.
   **NEVER rmmod while a faulting device is on the bus** — teardown wedges in-kernel
   and freezes the session.
3. Enclosure power switch off, 15 s, on.
4. Replug cable; module autoloads on attach; verify no IO_PAGE_FAULT in dmesg.
Also **NEVER** `echo 1 > .../remove` + rescan on a device the compositor holds open —
even "holds but not rendering." It freezes KWin. (Two frozen sessions prove both rules.)

**Soft losses.** Some losses are "soft": the tunnel stays `authorized`, the device stays
enumerated in lspci, and only driver-side state dies (`nvidia-smi` reports no devices).
The both-sides recovery above applies regardless. Note: PCIe-layer AER visibility for
these was only ever obtained under `pcie_ports=native`, which is removed — losses are
silent at the PCIe layer again, and that is the accepted trade.

**Separate issue — external display goes dark after DPMS off (amdgpu, NOT the eGPU).**
The monitor is on the laptop HDMI driven by the AMD iGPU; this has nothing to do with
the 5070 Ti. Signature at the moment it goes dark:
`amdgpu 0000:c4:00.0: [drm] enabling link 1 failed: 19` (-ENODEV) — the DPMS *re-enable*
fast path fails link training and does not retry, so input never wakes it. Opening the
folio (or any udev event) forces powerdevil/libddcutil full display redetection, which
retrains from scratch and succeeds. Keyboard-driven equivalent workaround:
`kscreen-doctor output.HDMI-A-1.disable && sleep 2 && kscreen-doctor output.HDMI-A-1.enable`
Hypothesis under test: the link is marginal because 4K120 + HDR + VRR on an HDMI **2.0**
cable requires DSC and sits at the bandwidth ceiling, so the fast re-enable fails where a
cold train succeeds. **Test in flight (from Aug 26 evening): dropped to 4K60**, HDR and
VRR left on, one variable. If stable for a few days → bandwidth confirmed → fix is a
certified 48 Gbps HDMI 2.1 cable, then 120 Hz + HDR can come back. If still dark at
60 Hz → drop VRR, then HDR. If none help, it's the amdgpu fast-path bug alone, which is
worth reporting upstream (amdgpu is actively maintained, unlike the rest of this stack).
kwin_wayland held DRM state on the card ~10h overnight with zero Xid after a cold-boot-present
attach. The fragile case remains hotplug-attach into a live session (Xid 79 on Aug 24). If
instability returns, re-add to `/etc/modprobe.d/99-nvidia-egpu.conf`:
`blacklist nvidia_drm`, `blacklist nvidia_modeset`, `softdep nvidia post: nvidia-uvm` — and set
`VK_DRIVER_FILES=/usr/share/vulkan/icd.d/radeon_icd.json` (note: NOT *.x86_64.json on CachyOS)
so Vulkan apps present via AMD.

**Does NOT work**
- **Driving the KDE/Wayland desktop from the eGPU.** Sparkles and blanking, reproducible.
  Tested against stock driver, a hand-written detection patch, and apnex's 5-patch set.
  Not a cable issue — the same short cable is stable on the AMD iGPU at the same mode.
  apnex runs compute-only and blacklists `nvidia_drm`/`nvidia_modeset`.
  **Correction (Aug 30):** display over a USB4 tunnel on Blackwell + Linux is NOT
  universally broken — DamianKA1993 reports working scanout on his Ryzen mini PC +
  AORUS 5060 Ti AI BOX driving a 2560x1080 ultrawide plugged into the enclosure (AAA
  gaming, CachyOS forum). That is (a) a different AMD USB4 host, and (b) ~1080p-class
  bandwidth. So the GZ302EA scanout failure is likely host-platform-specific (consistent
  with the stale-MPIO finding in the firmware analysis) rather than GSP-universal — and
  it raises the odds on the still-untested conservative profile (1080p60, no HDR/VRR)
  from open item 4.

**Cold-boot USB4 tunnel — VERDICT (Aug 25): unfixable locally, live with the replug.**
Symptom: at cold boot with enclosure attached, both NHIs register (domain0/domain1) but no
child device (`0-2`) appears; boltctl shows `disconnected`; `NVRM: No NVIDIA GPU found`.
~70% failure rate matches the upstream-documented AMD USB4 gap. Established tonight:
- Software replug does NOT work: unbind/rebind of both NHIs
  (`/sys/bus/pci/drivers/thunderbolt/unbind` → `bind` on c6:00.5/.6) leaves the device
  `disconnected`. The failure is below driver probe — USB4 CM/PHY level.
- `host_reset` removal didn't fix it; `pcie_ports=native` didn't fix it; hvico's rescan
  service can't fix it (it waits for a PCI device that never appears); no config does.
- Physical replug: 100% success all week. That's the workaround. Boot attached anyway
  (~30% it just works), replug when nvidia-smi says no.
Reference repos with the same hardware shape (none fix the cold-boot case):
apnex/nvidia-driver-injector (the patch set), hvico/Razer-Core-v2-Linux-Fix (GZ302EA +
Core X V2, but Ampere + proprietary driver — its `NVreg_EnableGpuFirmware=0` fix is a
NO-OP on Blackwell/open modules), cpburnz gist (Strix Halo + Core X V2, headless),
DamianKA1993/blackwell-egpu-manager (CachyOS/Plasma 6/Blackwell state-manager applet +
udev rules; stock modules, no driver patches; its Mode 4 removes the iGPU from the PCI
tree at runtime — do NOT use that on this machine, same operation class that froze the
session twice).
Real fixes to watch: kernel "thunderbolt: Fix PCIe device enumeration with delayed rescan"
(AceLan/Westerberg/Limonciello, Jan–Feb 2026) landing in a CachyOS kernel; ASUS GZ302EA
BIOS update (Minisforum shipped a TB fix for the same platform generation in their 1.05).

**GPU-loss → session deadlock (kernel bug, discovered Aug 25).**
When the GPU drops under display-path load with nvidia_drm loaded, C5 contains the driver
side (single `cleanupGpuLostStateAtomic: GPU N lost via detector_class=N` line — verified
in the field), but two `nvidia_dev_put` refcount WARNs fire in nvkms_close_gpu/nvidia_close
(C5 port follow-up gap, cosmetic), and then the systemd *user manager* can wedge in D state
inside `cgroup_lock_and_drain_offline` draining the dead process's cgroup. Symptom: no new
apps launch (Dolphin/Konsole dead, existing terminals fine), `ps aux | awk '$8 ~ /D/'`
shows systemd. Unkillable; reboot required (`sudo systemctl reboot`, add `--force` if it
stalls). This is a Linux cgroup bug interacting with tasks that died holding a vanished
device — reportable to kernel bugzilla, not fixable driver-side.

**Unresolved, unrelated to the GPU**
- ~~Shutdown does not power off.~~ **FIXED by a kernel update (observed Aug 30, on
  7.2.2-1-cachyos; last known-broken on 7.2.0).** The original attribution — "sysrq-o
  also fails, so it is ACPI S5 / firmware, not Linux" — was WRONG: a kernel change fixed
  it, so the trigger was in how Linux prepared the platform for S5 (likely device
  quiesce/teardown ordering), even though the hang manifested below the sysrq layer.
  Lesson recorded: "fails below Linux's last visible step" does not mean "not caused by
  Linux." This also withdraws the S5 leg of the SMU-firmware symptom mapping in
  `gz302ea-bios311-firmware-analysis.md` — the version-currency facts there stand, but
  S5 is no longer evidence for them.
- Suspend enters s2idle and never resumes. Requires hard power-off.
  `amd_pmc` is loaded and bound to `AMDI000B:00`, so not a missing-driver problem.
  **Worth one retest on ≥7.2.2** — the S5 fix proves this kernel range touched
  power-state paths relevant to this platform.

---

## Current configuration

### Kernel cmdline — `/etc/default/limine`, apply with `sudo limine-update`

```
gpiolib_acpi.ignore_wake=AMDI0030:00@58
pcie_aspm.policy=performance
pcie_ports=native
thunderbolt.clx=0
pcie_port_pm=off
pci=realloc=off
```

- `pcie_port_pm=off` — **required.** Without it the PCIe link drops ~1 s after the nvidia
  module loads (`pciehp: Link Down` / `Card not present`).
- `pcie_aspm.policy=performance` — minimizes ASPM transitions.
  **Never use `pcie_aspm=off`** on this AMD platform: it breaks the ACPI `_OSC` handoff
  (`OS requires [ExtendedConfig ASPM ClockPM MSI]`), the OS never takes PCIe ownership,
  and MSI-X allocation fails → `NVRM: Failed to enable MSI-X` → `RmInitAdapter failed! (0x22:0x56:894)`.
- `pci=realloc=off` — from a report with the identical Razer Core X V2. Replaced the earlier
  `pci=assign-busses,hpbussize=...,realloc`. An HPE advisory documents `pci=realloc` removing
  BIOS-assigned BARs without reassigning them.
- `thunderbolt.clx=0` — disables TB low-power lane states.
- `thunderbolt.host_reset=0` — **STILL ACTIVE** (correction, Aug 26: an earlier edit did
  not take; every boot in this log has run with `=0`. "Removing host_reset didn't fix cold
  boot" was therefore never actually tested — treat as an untested variable.)
  Originally added for: The `=0` advice is for
  resume-time tunnel protection (irrelevant here, suspend is disabled) and Intel-host ReBAR
  sizing. Default `true` resets the USB4v2 host router at probe — the kernel's built-in
  "replug" for boot-present topology. Removal did NOT fix the cold-boot lottery (see below).
- `pcie_ports=native` — **TRIED AND REMOVED (Aug 26). DO NOT RE-ADD.** Forces kernel-native
  PCIe control past the firmware `_OSC` denial. It does buy AER visibility on GPU loss
  (`AER: Uncorrectable (Non-Fatal) error message received from 0000:63:00.0`, previously
  silent) — but it **breaks MSI-X vector allocation on the hotplugged tunnel device**:
  `NVRM: GPU 0000:63:00.0: Failed to enable MSI-X.` → `RmInitAdapter failed! (0x22:0x38:859)`
  → with no interrupts the GPU DMAs into torn-down mappings: ~23,000 AMD-Vi IO_PAGE_FAULTs
  per second (addresses stepping by 0x20, `flags=0x0020`, plus `0xffe01000` = MSI region).
  Same failure class as `pcie_aspm=off` on this platform, same cause: overriding the
  platform's `_OSC` arrangement on firmware that denies those services. Removing it
  restores clean init immediately. Cold-boot tunnel behaviour was unaffected either way.
- `nvidia-persistenced` — disabled. It holds the module and blocks every `modprobe -r`.

---

## The patch set

Source: `https://github.com/apnex/nvidia-driver-injector` → `patches/base/`
Written against 595.71.05; **five of seven apply cleanly to 610.57.04**, and C5 applies via the rebased `C5-crash-safety-610.57.04.patch` (apply it AFTER the five base patches).

| Patch | Applies to 610? | What it does |
|---|---|---|
| `E1-egpu-detection` | ✅ | Rewrites `RmCheckForExternalGpu()` to use the kernel's own Thunderbolt classification (`os_pci_is_thunderbolt_attached()`) instead of walking the bus for TB3-era vendor IDs. **This is the fix.** |
| `C3-gpu-lost-retry` | ✅ | Retries `NV_PMC_BOOT_0` 10× at 100 µs before declaring the GPU lost. Stock driver commits to `PDB_PROP_GPU_IS_LOST` on a **single** `0xFFFFFFFF` read — routine link noise on a tunnel. |
| `C2-aer-internal-unmask` | ✅ | Clears AER Uncorrectable Mask at probe so real PCIe errors reach the kernel's handlers instead of being demoted to advisory correctables. |
| `C4-err-handlers-scaffold` | ✅ | Registers `pci_error_handlers`, which upstream open leaves empty. |
| `C6-cond-acquire-rwlock-fix` | ✅ | Inverted rwlock conditional-acquire primitive fix. |
| `C1-kbuild-version-mk` | ❌ | Build metadata only. **Skip — no value.** |
| `C5-crash-safety` | ✅ (rebased) | Ported to 610.57.04 as `C5-crash-safety-610.57.04.patch` (kept alongside the runbook). Guards ~36 files so a lost GPU is contained instead of cascading: single `GPU lost via detector_class=N` log line, no repeated dead-bus dump calls, DRM-layer dead-bus guards (110 lines in `nvidia-drm-drv.c`). Original failed on 610 only from context drift (`is_cxl_dev` added to `nv_state_t`, new include in `rs_server.c`). |

**Why detection failed before E1** — the old code required BOTH:
1. `approvedBusType == NV2080_CTRL_INTERNAL_EGPU_BUS_TYPE_TB3` (closed-source TB3 list — a TB5
   controller can never match), AND
2. `CL_PCIE_SLOT_CAP_HOTPLUG_CAPABLE && CL_PCIE_SLOT_CAP_HOTPLUG_SURPRISE`

The JHL9480 reports `SltCap: ... HotPlug- Surprise+`, failing the AND. Both gates missed, so
`PDB_PROP_GPU_IS_EXTERNAL_GPU` was never set and internal-GPU power management ran against a
device behind a PCIe tunnel.

Verify with: `sudo lspci -vv -s <upstream-bridge> | grep -i 'HotPlug\|Surprise'`

---

## Rebuild after a kernel update

The modules install to `/lib/modules/$(uname -r)/kernel/drivers/video/` and are **not**
DKMS-managed. After a kernel update you boot with no NVIDIA modules until you rebuild.

### CRITICAL: CachyOS kernels are built with Clang/LLVM

Always pass `LLVM=1 CC=clang LD=ld.lld` or the build fails at link with:
```
/usr/bin/ld: unrecognised emulation mode: llvm
*** Failed CC version check. ***
```

### Procedure

**1. Reboot into the new kernel first.** Verify they match:
```bash
uname -r; pacman -Q linux-cachyos linux-cachyos-headers
```

**2. Confirm the source tree is still patched:**
```bash
cd ~/open-gpu-kernel-modules && git diff --stat
```
Expect ~40 files, ~1330 insertions / ~132 deletions (5 base patches + rebased C5). If empty, re-apply (see below).

**3. Check userspace still matches:**
```bash
pacman -Q nvidia-utils   # must be 610.57.04
```
If pacman upgraded it, see "Userspace upgrade" below.

**4. Build and install:**
```bash
cd ~/open-gpu-kernel-modules && \
  make clean && \
  make -j$(nproc) modules LLVM=1 CC=clang LD=ld.lld && \
  sudo make modules_install -j$(nproc) && \
  sudo depmod -a && \
  modinfo nvidia | grep -E 'filename|version|vermagic'
```

`vermagic` must match the running kernel. SSL/`sign-file` errors are cosmetic — no signing key
in the kernel tree, and Secure Boot isn't enforcing.

**5. Reboot with the enclosure connected and verify:**
```bash
sudo dmesg -T | grep -iE 'external GPU detected|NVRM|Xid|transient'
nvidia-smi | head -12
```

Success looks like:
```
NVRM: loading NVIDIA UNIX Open Kernel Module for x86_64 610.57.04
nvidia 0000:63:00.0: external GPU detected (thunderbolt-attached=yes, external/untrusted=yes)
```

No Xid, no `RmInitAdapter failed`, no `Link Down`.

`transient PCIe read recovered after N retries` = C3 caught a glitch that would previously
have killed the card. That line is a **good** sign.

On any future GPU loss, C5's signature is a single `GPU lost via detector_class=N` line and
contained teardown — not the pre-C5 cascade of `nvdEngineDumpCallbackHelper` failures
hammering a dead bus.

### Re-applying the patches

```bash
cd ~/nvidia-driver-injector && git pull
cd ~/open-gpu-kernel-modules
for p in E1-egpu-detection C2-aer-internal-unmask C3-gpu-lost-retry \
         C4-err-handlers-scaffold C6-cond-acquire-rwlock-fix; do
  printf '%-35s ' "$p"
  git apply ~/nvidia-driver-injector/patches/base/$p.patch && echo OK || echo FAILED
done
git apply C5-crash-safety-610.57.04.patch   # rebased copy kept in ~/ or with this runbook
git diff --stat
```

Test first with `git apply --check` if unsure. If one fails mid-sequence, **stop** — later
patches may depend on earlier ones and a partial apply is worse than none.

### Userspace upgrade

Kernel modules and userspace libs must be the same version. When pacman moves `nvidia-utils`
past 610.57.04:

```bash
cd ~/open-gpu-kernel-modules
git fetch --tags && git tag | tail -20      # find the matching tag
git checkout <new-tag>
# re-apply patches; expect some to need porting
```

To pin instead, add to `/etc/pacman.conf`:
```
IgnorePkg = nvidia-utils lib32-nvidia-utils opencl-nvidia lib32-opencl-nvidia nvidia-settings
```

### Never install nvidia-open-dkms

It builds an **unpatched** module into `/lib/modules/$(uname -r)/updates/dkms/`, which takes
precedence over `kernel/drivers/video/`. Your patched module is silently shadowed.

```bash
pacman -Q | grep dkms
ls /lib/modules/$(uname -r)/updates/dkms/ 2>/dev/null
```

---

## Recovery

**Card missing after boot:**
```bash
sudo boltctl list; lspci -D -d 10de:; nvidia-smi
```
- bolt says `disconnected` → unplug/replug the TB cable. Nothing else helps.
- device listed but `sudo setpci -s <addr> VENDOR_ID` returns `ffff` → stale/D3cold. Remove the
  upstream bridge and rescan:
```bash
UP=$(basename $(dirname $(dirname $(readlink -f /sys/bus/pci/devices/$(lspci -D -d 10de: | head -1 | cut -d' ' -f1)))))
echo 1 | sudo tee /sys/bus/pci/devices/$UP/remove; sleep 3; echo 1 | sudo tee /sys/bus/pci/rescan
```

**Warnings:**
- A bare `/sys/bus/pci/rescan` on a stale device re-adds it **without resizing the parent bridge
  windows** → `NVRM: BAR0 is 0M @ 0x0`, every BAR fails. Remove the bridge first.
- **Never** run remove/rescan while the GPU is driving your session — it tears the DRM device out
  from under KWin: frozen display, TTY switching stops working, hard power-off required.

**No desktop after a display config change:** Ctrl+Alt+F2, then
`rm ~/.config/plasma-workspace/env/egpu.sh`, reboot. No sudo needed.

---

## Display notes

- **KWin output state lives in `~/.config/kwinoutputconfig.json`**, not `~/.local/share/kscreen`.
  Resetting the latter does nothing on Plasma 6 Wayland. Deleting the former fixed an inverted
  lid-open/close layout that survived every other reset.
- KWin prefers the AMD iGPU as render device even when NVIDIA is `card0`. That's deliberate on
  its part, not an accident.
- `KWIN_DRM_DEVICES` pinning to the eGPU **black-screened twice** and produced a KWin segfault
  during multi-GPU teardown. Not viable here.
- PowerDevil logs `There are no outputs - creating placeholder screen` constantly. It's a generic
  Qt Wayland message emitted during output reconfiguration by many processes — cosmetic.
- 4K120 HDR 10-bit works on the laptop HDMI over a **2.0** cable via DSC (~32 Gbps payload,
  ~18 Gbps link). The certified 48 Gbps **10-foot** cable was *less* stable — it advertised
  enough bandwidth to attempt uncompressed, then couldn't deliver at that length.
- Requesting **16 bpc** reproducibly triggers `amdgpu ... enabling link 1 failed: 19`.
  HDMI carries 8/10/12 bpc only. Stay at 10.
- `LnkSta` on a Thunderbolt-tunnelled device is **virtualized** by the TB controller and does not
  reflect real bandwidth. "Gen1 x4 (downgraded)" is a red herring — measure with `nvbandwidth`
  instead (~2.8 GB/s on TB4 is the tunnel saturated).

## Using the eGPU without pinning the compositor

Per-app offload — compositor stays on AMD:
```
__NV_PRIME_RENDER_OFFLOAD=1 VK_DRIVER_FILES=/usr/share/vulkan/icd.d/nvidia_icd.json %command%
```
CUDA needs nothing — it targets the card directly regardless of display topology.

---

## Upstream

- Issue: `NVIDIA/open-gpu-kernel-modules#979`
- PR #984 — `RmForceExternalGpu` registry key (detection only; does not fix crash-on-write)
- PR #981 — closed without merge
- apnex's repos: `apnex/aorus-5090-egpu` (investigation/forensics),
  `apnex/nvidia-driver-injector` (current, containerized)

Author's own framing: **a mitigation, not a fix.** Behaviour still varies by host.

**Patch-free counterexample (DamianKA1993, Sep 1):** the same JHL9480 bridge
(`HotPlug- Surprise+`), stock `nvidia-open` DKMS, zero kernel cmdline flags, zero
modprobe blacklists — stable on his Ryzen mini PC + AORUS 5060 Ti AI BOX, carried by
userspace alone: `NVreg_DynamicPowerManagement=0` at modprobe + P0 clock locks + his
udev attach-gating. So the patch set is not *universally* required on this bridge.
What does NOT transfer to the GZ302EA without retesting: (a) "zero kernel flags" —
`pcie_port_pm=off` was proven required here (link drops ~1 s after module load without
it); (b) his udev settling/gating operates at the PCI layer and cannot touch this
host's below-PCI cold-boot failure; (c) dropping C3/C5 forfeits the loss-containment
that demonstrably mattered on this tunnel (single-line loss signature vs. dead-bus
cascade + the cgroup session wedge). His "don't override platform ACPI" advice agrees
with findings here (`pcie_ports=native` / `pcie_aspm=off` broke MSI-X when *added*).
If a patch-free trial is ever wanted: one variable at a time — stock modules first with
the current cmdline intact, full launch gauntlet + attach/detach cycles, and expect
losses (if any) to be uglier without C5. Not scheduled; current config is validated and
stable.

**`NVreg_EnableGpuFirmware=0` does NOT apply to Blackwell.** It appears in eGPU guides
(hvico's GZ302EA+Core X V2 repo with an Ampere 3090, cpburnz's Strix Halo gist) because on
the proprietary driver through Ada it falls back to legacy CPU-based RM and sidesteps GSP
entirely. Blackwell requires the open modules; the open modules always run GSP. The knob is
a silent no-op here — do not chase it.


---

## Open items as of Aug 26 evening

1. **HDMI 4K60 test running** — see the amdgpu link-training section. Watch for
   dark-after-blank episodes over the next few days.
2. **Publish the patch bundle** — `nvidia-610.57.04-egpu-patches.tar.gz` (README + GPL-2.0
   LICENSE + 6 numbered patches, validated end-to-end on a pristine 610.57.04 tree:
   37 files / +1330 / -132). Suggested repo `nvidia-610-egpu-patches`; topics: egpu,
   nvidia, thunderbolt, usb4, blackwell, open-gpu-kernel-modules. Discoverable from
   issue #979 without posting in that thread.
3. **Firmware analysis** — `gz302ea-bios311-firmware-analysis.md`: ASUS 311 ships SMU
   A.64.2.0 (7 revs behind) and MPIO 0.10.2.FA (4 revs behind) vs Minisforum 1.09 on
   current AMD PI. Candidate destinations: drm/amd work item 5208 (as an affected-machine
   fingerprint), the ROG forum BIOS-311 thread, strixhalo.wiki.
4. **Untested variables** — `thunderbolt.host_reset` has never actually been tested
   removed (the earlier edit didn't take). A conservative eGPU display profile
   (1080p60, no HDR/VRR) has never been tried. Zink for GL titles is untested.
5. **Audit before installing** blackwell-egpu-manager: read `install.sh`, its udev rules,
   and the sudoers scope. Its "prevent PCIe link stalls / improper driver auto-binding"
   udev rules are the interesting part (adjacent to the GL-context-creation failure);
   avoid Mode 4 entirely.
6. ~~**S5 poweroff test** with the eGPU cable fully detached~~ — SUPERSEDED: S5
   poweroff fixed by kernel update (7.2.2), see the Unresolved section. Follow-up
   worth watching instead: whether the same kernel range changed the **cold-boot
   tunnel lottery** — the watched fix ("thunderbolt: Fix PCIe device enumeration
   with delayed rescan") may have landed in this window. Track cold-boot success
   rate on ≥7.2.2 before concluding the ~70% failure figure still holds.
7. **Persistent journal** is worth enabling for future crashes:
   `sudo mkdir -p /var/log/journal && sudo systemd-tmpfiles --create --prefix /var/log/journal && sudo systemctl restart systemd-journald`
   Then `journalctl -b -1 -k` reads the previous boot after a hard crash.
