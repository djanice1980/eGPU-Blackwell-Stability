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
  **Sep 5 revision:** that 8/8 was measured while `NVreg_DynamicPowerManagement` was
  silently 2 (see CORRECTION below). With DPM=0 actually in effect, **5 unlocked
  launches + hours of play = 0 fatal, 1 non-fatal `Xid 32`**. GL titles now work
  *without* the lock; the lock is optional belt-and-braces. See the gauntlet result.
- Monitor on the **laptop's** HDMI at 4K120 HDR 10-bit (via DSC), KWin on the AMD 8060S

**CURRENT CONFIGURATION (Aug 26, evening): full display stack loaded.**
`nvidia_drm` + `nvidia_modeset` load normally. `/etc/modprobe.d/99-nvidia-egpu.conf`
holds only the three NVreg options + `softdep nvidia post: nvidia-uvm`. No blacklists,
no EGL/Vulkan pins, no `KWIN_DRM_DEVICES`. Monitor on the laptop HDMI (AMD 8060S).
**CORRECTION (Sep 5): `NVreg_DynamicPowerManagement=0` was NEVER in effect.** The driver
reports `DynamicPowerManagement: 2` (`/proc/driver/nvidia/params`). A distro-shipped
modprobe file carries `options nvidia … NVreg_DynamicPowerManagement=0x02`, and because
letter-named files sort *after* `99-…` in modprobe.d, its value is passed last and wins
(kernel module params: last assignment wins). The patches README's "99- prefix matters"
advice is insufficient — the override file must sort after every letter-named file
(`zz-nvidia-egpu.conf`) or shadow the distro file by name in `/etc/modprobe.d`. In
addition NVIDIA's own `/usr/lib/udev/rules.d/71-nvidia.rules` sets the GPU's
`power/control=auto`, so the kernel is *permitted* to runtime-suspend the card
(`d3cold_allowed=1`); the driver's own view is `Runtime D3 status: Not supported` and the
card has never actually runtime-suspended (`runtime_suspended_time=0`), so the practical
effect so far is unknown — but every result in this runbook was obtained under DPM=2,
not 0. **Fix applied Sep 5:** override renamed to `zz-nvidia-egpu.conf`; udev rule now forces
the GPU + HDA function to `power/control=on` (verified `on` immediately, pre-reboot).
`DynamicPowerManagement: 0` takes effect at the next module load (reboot) — verify with
`grep DynamicPowerManagement /proc/driver/nvidia/params`. **VERIFIED Sep 5 after reboot:
`DynamicPowerManagement: 0`.** Visible driver-side difference: `/proc/driver/nvidia/gpus/<bdf>/power` now reports `Runtime D3 status: Disabled` (under DPM=2 it said `Not supported`); GPU and HDA function hold `power/control=on` via the udev pin (matched by vendor/class, so it followed the card to `63:00.0`). Every stability result after this point is under DPM=0;
earlier ones (clock-lock 8/8, sustained-play Xid 31, scanout re-test, all tally rows
before this one) were under DPM=2. Note the eGPU can enumerate on either USB4 domain
(`0-2` → GPU `03:00.0` via root port `00:01.1`, or `1-2` → GPU `63:00.0` via `00:01.2`),
so never hardcode the GPU's bus address — match by vendor/class (the udev rule does). Upstream context: NVIDIA/open-gpu-kernel-modules
#1228 / #1229 (same GZ302EA + Core X V2 host, RTX 5090).

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
  **Re-tested Sep 4 on BIOS 314 / kernel 7.2.3 / host_reset default / port-pin udev:**
  monitor moved directly to the 5070 Ti, KWin ran it as `HDMI-A-2` at 3840x2160@119.88
  + HDR + WCG (clock lock OFF; card at P0 from load). Clean for ~90 s with **no sparkles**
  — then sparkles, and the identical Aug 11 signature: `Xid 56` (display engine) at
  16:54:21 → `Xid 56` + **`Xid 31` MMU fault by `kwin_wayland`** at 16:55:14 →
  `Pageflip timed out! This is a bug in the nvidia-drm kernel driver` every second →
  `Flip event timeout on head 0` / `Lost display notification`. Escape that worked:
  physically moving the HDMI cable back to the laptop port *before* KWin wedged; KWin
  re-detected the monitor on amdgpu, the card stayed alive (nvidia-smi answered, P5).
  **Afterwards the card kept working for render offload with NO both-sides reset** — the
  driver never declared the GPU lost, so a display-path Xid 56/31 is survivable if the
  output is removed before that happens. First time a GPU-error episode ended without
  the recovery procedure. **Precision (from the journal):** zero Xids for the next 14 min
  of use; but `nvidia-modeset` was still wedged on the dead head — `Error while waiting
  for GPU progress` every 5 s from 17:09:33 once the session started shutting down — and
  the reboot's tunnel teardown then produced `Xid 79 GPU has fallen off the bus` +
  `detector_class=1` at 17:10:07 (reboot.target already queued that second). So: the
  *render* side survived; the *display-engine* side did not, and would have needed a
  reboot anyway. Expect a shutdown-time Xid 79 after any such episode; it's not a new loss.
  Snapshot: `~/egpu-scanout-20260904-165524.log`. **Verdict (Sep 6): the display limit is
  sustained scanout stability, NOT bandwidth — and 1080p60 is the stable ceiling.**
  Ladder test Sep 6 (clocks locked 2000-max/14001, DPM=0, eDP kept as fallback,
  `tools/egpu-display-test.sh` v2 which refuses to run unlocked and disables the output on
  mismatch/first Xid):
  - **1080p60 SDR: STABLE.** 12 min sustained motion, 0 Xid, 0 pageflip. First proof the
    cross-GPU real-time scanout path works at all on this host. Usable as a daily config.
  - **1440p60: not offered** by the test monitor over the eGPU HDMI (only 1440p120 exists).
  - **4K60 SDR: LIT CLEAN, then HARD-FROZE ~5 min into real load.** The modeset itself
    committed with zero kernel errors (contrast the Aug/Sep 4 attempts that sparkled
    immediately), so 4K60 is within link margin — 3840×2160×4 B×60 Hz ≈ 2.0 GB/s, ~52% of
    the 3.86 GB/s tunnel. It is sustained scanout that fails, not the initial mode. The
    freeze was a full hard lock (no journal Xid captured — journald died with it); reboot
    left the GPU off-bus behind a healthy tunnel (card GSP wedged, enclosure fine).
    Recovery: enclosure power-cycle (15 s) resets the card, then `echo 1 >
    /sys/bus/pci/devices/0000:62:00.0/rescan`; the laptop EC drain was NOT needed (that is
    only for when the *tunnel* is also dead — see [[z13-egpu-freeze-ec-recovery]]).
  - **1080p120 + HDR + VRR auto: STABLE.** 10 min sustained motion, 0 Xid (Sep 6, log
    `egpu-display-test-20260906-010518.log`). This clears refresh rate (120 Hz), HDR, and
    VRR-auto as the trigger — none of them is the cause.
  - 4K60 HDR and 1440p120 deliberately NOT run: 4K60 SDR already froze, and the stable runs
    isolate the variable without them.
  **Config confirmed (Sep 6, KWin supportInformation):** the compositor renders on the
  **AMD iGPU** (`OpenGL renderer: AMD Radeon 8060S Graphics`, radeonsi/Mesa); card0=nvidia
  drives `HDMI-A-2` as **scanout-only** (0%% render util, ~30 W). So the whole ladder is
  iGPU-rendered frames copied across the tunnel for the 5070 Ti to scan out — and the 4K60
  freeze happened with the card **compute-idle**. It is the tunnel scanout-copy path that
  hits the ceiling, not GPU load. Corollary: a game run in THIS config renders on the iGPU
  and gets iGPU performance — the card does no rendering. The untested alternative is a game
  rendered ON the 5070 Ti with the monitor also on it: finished 4K frames then never cross
  the tunnel (only assets/commands do), so it may survive 4K where iGPU-render->eGPU-scanout
  froze. That is a separate test worth running before concluding the card can't be a 4K
  gaming display.
  **Refined verdict (Sep 6): the trigger is pixel THROUGHPUT on the real-time scanout path,
  not resolution/refresh/HDR/VRR per se.** Stable: 1080p60 (~0.5 GB/s), 1080p120+HDR
  (~1.2 GB/s). Freezes: 4K60 (~2.0 GB/s). The boundary sits ~1.2-2.0 GB/s — far below the
  3.86 GB/s the tunnel does for BULK copies, because the display engine's latency-sensitive
  real-time path has a much lower usable ceiling than render-and-hand-off. Practical: any
  1080p mode (incl. 120 Hz + HDR) is usable as a daily eGPU display; 4K is not.
  So: 1080p60 SDR is safe and usable; anything at 4K hard-freezes under load on this host.
  Do not attach a 4K display to the eGPU for real use. The old blanket "do not attach a
  display" is now narrowed to "4K scanout under load is the failing case."
  **Bandwidth hypothesis (Sep 5) — quantitative:** with KWin compositing on the AMD iGPU
  and the monitor on the eGPU, every frame crosses the tunnel to the card that scans it
  out: 3840×2160×4 B×120 Hz ≈ **4.0 GB/s**, above the measured **~2.8 GB/s** tunnel
  ceiling (`nvbandwidth`). 4K60 ≈ 2.0 GB/s (marginal), 1440p120 ≈ 1.8 GB/s, 1080p60 ≈
  0.5 GB/s. Fits the signature (late frames → pageflip timeouts; GPU faults on imported
  host buffers → `Xid 31 FAULT_PDE` by kwin_wayland) and the "clean until something
  animates" honeymoon (KWin only pushes frames on damage). Games are fine because
  finished frames flow the *other* way at game rates. **Measured Sep 4 (GPU-PCIe-Test v3.0, Vulkan, 256 MB copies):** CPU→GPU 2.37 GB/s,
  GPU→CPU 2.35 GB/s, bidirectional 3.44 GB/s — "94% of Thunderbolt 3"; use **2.37 GB/s
  host→GPU** as the ceiling for display copies. Shares: 1080p60 21%, 1440p60 37%,
  1080p120 42%, 1440p120 75%, 4K60 85% (too tight), 4K120 168%. The widget's PCIe line
  (nvidia-smi dmon TLP counters) over-reads ~2× versus measured payload — an activity
  indicator, not a measurement.
  **Revised Sep 5 — the 2.37 GB/s figure was contended.** Re-measured with GPU-PCIe-Test
  v3.4.1 (UI rendered on the iGPU, native Wayland — the tester'"'"'s own window no longer
  competing on the eGPU): **GPU→CPU 3.91 GB/s, CPU→GPU 3.86 GB/s, bidirectional 5.96
  GB/s**, two identical runs, zero Xids. That is the 32 Gbps PCIe-tunnel allocation of a
  40 Gbps USB4 link (~4.0 GB/s cap) — the tunnel is *not* TB3-class after all. Use **3.86
  GB/s host→GPU** as the display-copy ceiling. Revised shares: 1080p60 13%, 1440p60 23%,
  1080p120 26%, 1440p120 46%, **4K60 52% (now plausible)**, 4K120 104% (still over).
  Lesson: any bandwidth number taken while something else was rendering on the eGPU
  (including the benchmark'"'"'s own GUI) understates the tunnel. Prediction: 1080p60 SDR works;
  4K120 never will in this topology. Likely what #1229's reporter does differently: a
  lower mode, or KWin rendering *on* the 5090 (no per-frame copy) — ask them.
- Workarounds for GL titles: Zink (`MESA_LOADER_DRIVER_OVERRIDE=zink GALLIUM_DRIVER=zink`,
  drop `__GLX_VENDOR_LIBRARY_NAME`) routes GL through Vulkan — untested; or just run
  older GL titles on the 8060S, which handles them easily.
- **Fragile — MMU fault during sustained play (NEW, Sep 1, distinct from the launch
  killer):** a title that launched clean and ran **over an hour** died mid-session with
  `Xid 31 … MMU Fault: ENGINE GR_HOST0 HUBCLIENT_ESC0 faulted @ 0x100_00000000 …
  FAULT_PDE ACCESS_TYPE_VIRT_READ` (Wolfenstein: TNO). ~1 h later the driver declared the
  GPU lost (`cleanupGpuLostStateAtomic: GPU 0 lost via detector_class=0`, then Xid 154 /
  PF FLR). This is **not** the P-state context-creation death — it is a virtual-memory
  page fault deep into a running render, a different and much rarer failure class (same
  Xid 31 MMU-fault family seen on the scanout path). **Clocks were OFF for this run**, so
  it does not undercut the clock-lock result, but it also is not yet known whether locks
  help here — locking targets P-state transitions, and a mid-render MMU fault may be
  independent of clocks. Open test: a full locked long-session (P0 held) to see whether
  this fault recurs. C5 contained it cleanly (single detector_class line, no dead-bus
  cascade, no cgroup/D-state wedge). Recovery notes for this one: see the soft-loss
  procedure below — the device kept answering config reads (soft loss), and unplugging the
  cable with `nvidia_drm` still loaded froze the display (KWin held the DRM node).

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

**Unlocked-launch gauntlet under DPM=0 (Sep 5, in progress):** with
`NVreg_DynamicPowerManagement=0` finally in effect (see CORRECTION above), testing whether
the clock lock is still required. Launch 1 (Wolfenstein: TNO, P8 unlocked, Proton):
**`Xid 32`** (invalid/corrupted push buffer stream, pid = the game, channel 0x20) 16 s
after launch — a corrupted command stream during the P8→P0 ramp. Different and milder
than the old launch killer: no `BadTimeLo`, no GSP heartbeat timeout, no Xid 154, no GPU
loss; **the game came up and played fine** — the Xid 32 was non-fatal to both the app and the card (nvidia-smi fine, P8 afterwards). Only one Xid this boot.
**Result (Sep 5, one 5 h boot, card unlocked throughout, verified P8/300 MHz at idle):**
~5 distinct Proton launches (17:20, 17:30, 17:39, 21:36, 21:50 — Wolfenstein: TNO
sessions plus a GPU benchmark), hours of play. **Exactly one Xid the whole boot** — the
non-fatal `Xid 32` above. No `Xid 154`, no heartbeat timeout, no GPU loss, no
sustained-play `Xid 31`. Against the ~75%-fatal launch baseline, five clean unlocked
launches is p≈0.001 by chance. **Conclusion: the DPM=2 misconfiguration was a major
driver of the launch killer; DPM=0 (properly in effect) removes the *fatal* outcome. The
clock lock was compensating for it.** The residual `Xid 32` shows the tunnel still glitches
across the P8→P0 ramp, so the lock remains a legitimate belt-and-braces for a zero-Xid
session (at its ~20 W idle cost) — but it is no longer *required* to game. Standing
config: **DPM=0 mandatory; clock lock optional.** The Aug 30 "8/8 with locks" result
stands as a valid observation under DPM=2; it should not be read as "locks are the fix".
**Counter-evidence (Sep 4, 23:41, same 5 h boot, DPM=0, unlocked):** running the latest
build of the GPU-PCIe-Test tool (Vulkan DMA bandwidth/latency loops, 256 MB copies,
"CPU round-trip" latency method) produced the **original GSP death**:
`GSP_LOCKDOWN_NOTICE` → `tmrGetTimeEx_GH100: Consistently Bad TimeLo value ffffffff` →
`_kgspIsHeartbeatTimedOut` → `LibOS heartbeat timed out` → `Xid 154 (PF FLR)` → teardown
asserts. Soft loss (device answers config reads, tunnel `link=usb4`, no IO_PAGE_FAULT, no
D-state). So DPM=0 made **game launches** survivable (5/5 + hours of play), but a
DMA-hammering test app still reached the GSP-hang class. The hazard is reduced, not
eliminated; whether the clock lock would have prevented this run is unknown (it was off).
Precursors in the log: the tester (`AppRun`) threw `Xid 32` (corrupted pushbuffer) at 23:32:10 on an earlier run and again at 23:40:45, five seconds after this run started; the GSP heartbeat died 72 s later. C5 contained it (`cleanupGpuLostStateAtomic: GPU 0 lost via detector_class=0`, single line) and its known cosmetic `nvidia_dev_put` refcount WARN (nv.c:5361) fired in the app's teardown. Log: `~/egpu-gsp-loss-20260904-234430.log`. Practical rule: PCIe stress testers are the
riskiest workload on this tunnel — lock clocks before running one, or expect a reset.
**Deterministic reproducer found (Sep 4, 23:49, fresh boot after the both-sides reset,
clean attach at 19.3 s):** merely *opening* GPU-PCIe-Test 3.4.0 — no benchmark started —
produced `Xid 32` on its channel **5 s after launch** (pid = `AppRun`, identical method
words `8006006c`/`8006005c` as the two hits the night before). The app's Vulkan device is
lost (its GPU list goes empty — looks like "the 5070 Ti is gone"), but the driver and card
survive: `nvidia-smi` answers, config reads answer, other clients work. So the tool's
startup path does something — a probe/warm-up transfer or timestamp query during device
creation — that corrupts a command stream over the tunnel every time. Same
"state creation across the tunnel" phase as the GL launch killer; under DPM=0 it stays a
channel error unless something (the full benchmark last night) escalates it to a GSP
heartbeat loss. **Identified (Sep 4/5):** not a startup probe at all. The clean v3.0 run and the faulting
3.4.0 runs execute the same GUI code; the difference is the binary. The 3.4.0 **AppImage
bundles GLFW 3.3.6 built X11-only** (no Wayland symbols), so its window is an **XWayland
client** while the GUI renders on the eGPU (`InitVulkan` picks the first *discrete* GPU
for the UI) — every frame is presented through Xwayland'"'"'s cross-GPU buffer sharing.
The v3.0 binary used the system GLFW 3.5.1 with native Wayland, where KWin imports the
NVIDIA dma-buf directly, and ran a full benchmark with zero Xids. So the reproducer is
"eGPU-rendered window presented via XWayland" — the same imported-buffer-across-the-tunnel
family as the monitor-on-eGPU Xid 31/56 failure, at window scale. `vulkaninfo` (no
window) doesn'"'"'t trigger it. A/B prepared: the AppImage extracted with its bundled GLFW
removed (`~/Downloads/gpu-pcie-test-3.4.0-sysglfw/squashfs-root/AppRun`) runs native
Wayland; the v3.0 binary forced to X11 (`WAYLAND_DISPLAY= ~/Downloads/gpu-pcie-test-vulkan`)
should reproduce. Fix for the tool: ship a Wayland-capable GLFW (≥3.4) in the AppImage,
and/or render the GUI on the *integrated* GPU when the benchmark target is a tunneled eGPU.
**Sep 5 evening: the widget's lock/pin toggles and the root helper (sudoers entry,
`egpu-clocklock.service`, its udev rule) were removed** — the widget is read-only again.
**Gotcha (Sep 5):** the clock-lock uninstaller did `rm -rf /etc/blackwell-egpu`, which also
deleted the pacman hook's config that lived there. The hook config now lives at
`/etc/nvidia-egpu-rebuild.conf` (own file, nothing else touches it); after any such
cleanup re-run `sudo bash pacman-hook/install-hook.sh`, then `sudo nvidia-egpu-rebuild`
must report "already installed -- nothing to do" — otherwise the next kernel update boots
driverless.
**Gotcha:** the clock-lock uninstaller did `rm -rf /etc/blackwell-egpu`, which also deleted
the pacman hook's `rebuild.conf` (same directory). After removing the helper, re-run
`sudo bash pacman-hook/install-hook.sh` — otherwise the next kernel update fails with
"rebuild.conf missing" and boots driverless.
Manual lock, if ever wanted for a zero-Xid session:
`sudo nvidia-smi --lock-gpu-clocks=2000,3210 && sudo nvidia-smi --lock-memory-clocks=14001,14001`
(reset with `--reset-gpu-clocks --reset-memory-clocks`).

**Recovery procedure after ANY GPU death.** A host reboot alone does NOT reset the card
(enclosure keeps it powered; wedged GSP persists). An enclosure power-cycle alone does NOT
clear the host (driver reuses stale state → AMD-Vi IO_PAGE_FAULT storm at re-probe,
repeating identical addresses). BOTH sides must reset — but **the ORDER depends on
whether it is a soft or hard loss.** Decide first:

```
setpci -s <gpu-addr> VENDOR_ID     # e.g. 03:00.0
```
- Returns `10de` (device still answers config reads, no fault storm in dmesg) = **SOFT
  loss** — the tunnel stays `authorized`, device still in lspci, only driver-side state
  died (`nvidia-smi` reports no devices).
- Returns `ffff`, or dmesg is storming `IO_PAGE_FAULT` = **HARD loss / faulting device.**

**SOFT loss — unload modules BEFORE unplugging (corrected Sep 1, learned the hard way):**
1. Quit the app holding the GPU (the game window).
2. `sudo fuser -k /dev/nvidia*` if anything still holds it.
3. `sudo modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia` — unload the DRM node
   FIRST, while the device is on the bus but no longer faulting. This releases KWin's
   handle cleanly. (Module busy = something still holds it; find with `fuser`, don't force.)
4. THEN unplug the TB cable.
5. Enclosure power switch off, 15 s, on.
6. Replug; module autoloads on attach; verify `external GPU detected`, no Xid.
   **If you cannot close every holder** (`fuser -v /dev/nvidia*` — e.g. an Electron app
   you are working in, or anything you'd rather not kill), the unload will fail (`nvidia`
   stays busy). Use the **reboot both-sides reset** instead: reboot the laptop; while it is
   down, enclosure power switch off ≥15 s then on; boot with the cable attached. A host
   reboot alone does NOT reset a wedged GSP — the enclosure cycle is the part that matters.
   Expect benign shutdown-time noise (`Xid 79` / `detector_class` as the tunnel tears down).
   **Why this order:** with `nvidia_drm` loaded, KWin holds the card's DRM node open as a
   *secondary* device even though it composits on the AMD 8060S. Pulling the cable first
   rips that node out from under the compositor → **both displays freeze** (OS stays
   responsive underneath; hard power-off required). Confirmed Sep 1.

**HARD loss / faulting device — cable OUT first (original order):**
1. Unplug the TB cable FIRST (device off the bus).
2. THEN `sudo modprobe -r nvidia_uvm nvidia` — instant with the device gone.
   **NEVER rmmod while a faulting device is on the bus** — teardown wedges in-kernel and
   freezes the session.
3. Enclosure power switch off, 15 s, on.
4. Replug cable; module autoloads on attach; verify no IO_PAGE_FAULT in dmesg.

Also **NEVER** `echo 1 > .../remove` + rescan on a device the compositor holds open —
even "holds but not rendering." It freezes KWin. (Frozen sessions prove all these rules.)

Note: PCIe-layer AER visibility for soft losses was only ever obtained under
`pcie_ports=native`, which is removed — losses are silent at the PCIe layer again, and
that is the accepted trade.

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
cold train succeeds.
**Sep 4 event — the picture changed.** Dark after DPMS again, but this time: (1) the kernel
logged **nothing** — no `enabling link 1 failed`; (2) powerdevil's libddcutil display
redetection ran at 08:27 (`Display redetection finished`) and did **not** recover it;
(3) `kscreen-doctor output.HDMI-A-1.disable/enable` at 08:30 did recover it — kernel showed
a fresh modeset with `HDR SB:` infoframes. So the failure is not (only) amdgpu link
training, and the "any udev event fixes it" rule is not reliable. Monitor EDID
(edid-decode, LG GSM/49352): FRL max **6 Gbps × 4 lanes = 24 Gbps**, **DSC 1.2a**, VRR
40–120 Hz, 10/12-bit deep color. 4K120 10-bit HDR needs ~40 Gbps uncompressed → the link
is FRL+DSC, i.e. the most fragile wake negotiation. Active profile at the time: 4K120,
HDR on, WCG on, VRR Never (the Aug 26 "4K60 test" turns out to live in a *different*
lid-state entry of `kwinoutputconfig.json`, so it was never actually in effect here).
Controlled repro is available — no need to wait for idle blanking:
`kscreen-doctor --dpms off` then wake with input. Ladder, one variable per step:
(a) reproduce at 4K120+HDR; (b) HDR off (`kscreen-doctor output.HDMI-A-1.hdr.disable`),
same mode; (c) 4K120 SDR → 4K60 SDR; (d) 1080p60. If (d) still fails → amdgpu/KWin DPMS
bug independent of bandwidth; if it survives from (b) on → HDR re-enable on wake is the
trigger; if only (c)/(d) survive → FRL/DSC bandwidth margin.
**Ladder result (Sep 4): more stable at lower resolution/refresh** — i.e. bandwidth sets
the margin. Refined from recollection (not re-verified): with IPS still enabled, **4K120
+ HDR failed; 4K120 HDR-off passed; 4K60 passed.** Since 4K120 8-bit is still above the
sink's 24 Gbps FRL ceiling (same FRL+DSC link class as the HDR mode), the discriminator
is the HDR/10-bpc configuration, not bandwidth — the IPS exit fails to re-lock the link
when HDR metadata / deep color is active. **But the decisive control is Windows on the same host + same monitor + same
cable: never fails.** A second monitor/cable at work fails the same way on Linux and never
did on Windows. Cable and monitor are exonerated; this is Linux's DPMS re-enable path.
**Upstream context (Sep 4, corrected after digging):**
- Display core: **DCN 3.5.1**, DC v3.2.384, DMUB 0x09004E00. The HDMI port is behind a
  **DP-to-HDMI FRL PCON** (`[drm] DP-HDMI FRL PCON supported`) — FRL training happens in
  the converter, driven over DPCD. The work monitor goes through the same PCON.
- HDMI FRL+DSC support in amdgpu is new in 7.2 (series "HDMI FRL and DSC Support for
  amdgpu", May 2026) — relevant, but NOT the whole story:
- A 6.18-era regression, commit 3471b9a31ce3 "drm/amd/display: Rework HDMI data channel
  reads" (SCDC/scrambling init skipped → LG sink "No Signal" after power-cycle, 7900XTX),
  was **fixed** by "drm/amd/display: Improve HDMI info retrieval"; the running module
  already carries the fix's `skip_scdc_overwrite` path, so that one is likely not ours.
- **Still open and the closest match:** "External HDMI monitor fails to wake up from
  DPMS/consoleblank since kernel 6.18" (amd-gfx, Jan 2026) — Radeon 880M/890M, i.e.
  **DCN 3.5 like this machine**, external HDMI dark after DPMS while eDP resumes, 6.17
  fine. Alex Deucher asked for a bisect + gitlab ticket; none visible. No bisect done.
- DCN 3.5 has **IPS (idle power states)**, which engages precisely when displays blank.
  Prime suspect for the APU-specific variant. Testable with one documented flag.

**Decisive test ladder (cmdline, one reboot each, then `kscreen-doctor --dpms off` + wake
at 4K120/HDR):**
1. `amdgpu.dcdebugmask=0x800` (DC_DISABLE_IPS). Survives → IPS exit path is the bug.
2. else `amdgpu.dcdebugmask=0x4` (DC_DISABLE_DSC) — forces non-DSC link; if the driver
   then can't do 4K120 10-bit, that itself narrows it to the DSC/FRL re-enable path.
3. else it's PCON FRL re-training on re-enable — report as such.
(Bit values from `enum DC_DEBUG_MASK`, drivers/gpu/drm/amd/include/amd_shared.h.)
Runtime check of IPS state (root): `cat /sys/kernel/debug/dri/1/amdgpu_dm_ips_status`.
**Step 1 result (Sep 4): CONFIRMED — 6/6 clean wakes at 4K120 + HDR with IPS disabled.**
With `amdgpu.dcdebugmask=0x800` on the cmdline (`dcdebugmask=2048`;
`amdgpu_dm_ips_status` shows `IPS config: 1` = DMUB_IPS_DISABLE_ALL and all IPS
entry/exit counts 0), the deterministic repro that previously failed at this mode passed
once by hand and then 5/5 in a scripted run (`dpms-cycle.sh`, log
`~/dpms-cycle-20260904-1112.log`). **Re-validated Sep 7 at full-rate FRL** (10-bit BT2020 RGB, after
`dcfeaturemask=0x402` — the Sep 4 runs were unknowingly on the 8-bit 4:2:0 link): **5/5**,
log `~/dpms-cycle-20260907-1020.log`. The IPS fix holds on the heavier link. **Mechanism: DCN 3.5.1 IPS entry during DPMS-off with
an exit path that does not bring the PCON-attached HDMI link back**, while eDP recovers
and the driver logs nothing. **`0x800` is now standing config.** Cost: the iGPU display
core skips its idle power states — roughly a few hundred mW to ~1 W at idle, no
functional loss. Meta+Shift+D rescue stays as belt-and-braces. Steps 2/3 of the ladder
are moot. This also retro-explains every earlier clue: Windows fine (different IPS exit
handling), eDP fine (different link), lower modes more tolerant (cheaper re-lock), no
kernel error (driver believes the exit succeeded).
Side note seen on the same boot: the external display stayed dark on the **plasmalogin**
greeter (Plasma's login manager; its own KWin runs as user `plasmalogin`) and only lit
after login. Diagnosed with `greeter-display-diag.sh`: the greeter's KWin *did* detect and
configure HDMI-A-1 (its `/var/lib/plasmalogin/.config/kwinoutputconfig.json` holds the LG
at 3840x2160@120, HDR off) and logged **no** output errors for the whole greeter phase;
the only error is `atomic commit failed: Permission denied` at login = losing DRM master
to the user session, expected. So it's the same silent-failure class at *first light-up*
of a 4K120 FRL/DSC link, not IPS (which was already disabled on that boot). Cosmetic.
If it recurs: `sudo bash ~/Downloads/greeter-hdmi-4k60.sh` pins the greeter's LG entry to
3840x2160@60 (backs up the file first); the user session keeps its own 4K120/HDR config.
Schema note: outputs in `kwinoutputconfig.json` are keyed by `connectorName` +
`edidIdentifier`/`edidHash`/`uuid`, `mode.refreshRate` is in mHz — the "4K60" entry in
the user config belongs to a different (office, `YCT 23201`) monitor, which is why the Aug
26 "4K60 test" on the LG never actually took effect.

Report target: gitlab.freedesktop.org/drm/amd (draft in `docs/dpms-wake-bug-report.md`),
citing the 890M thread as the same bug on DCN 3.5. Mitigation in place: **Meta+Shift+D**
runs `~/.local/bin/display-rescue` (disable/enable every connected external output → full
modeset). Registered via KGlobalAccel DBus (`doRegister` + `setShortcut`, key int
0x12000044 = Meta+Shift+D); on Plasma 6.7 the shortcut daemon lives inside kwin_wayland. **Test in flight (from Aug 26 evening): dropped to 4K60**, HDR and
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

**Cold-boot tally since kernel 7.2.2 / BIOS 314** (enclosure attached at power-on;
"success" = child router `N-2` appears and `external GPU detected` without a replug).
The ~70% failure figure above was measured on kernel 7.2.0 + BIOS 311 — re-baseline here:

| Date | Kernel | BIOS | Result | Notes |
|---|---|---|---|---|
| Aug 30 14:19 | 7.2.2 | 311 | success | tunnel up, card enumerated (driverless boot, see kernel-update trap) |
| Sep 3 11:06 | 7.2.2 | 311 | success | `thunderbolt 0-2: Razer Core X V2` 6 s after USB init — firmware-prebuilt tunnel preserved by `host_reset=0` |
| Sep 3 13:19 | 7.2.2 | **314** | FAIL | first boot after the flash (settings reset) — contaminated sample; `usb4_port link=none`, USB3 fallback |
| Sep 3 13:5x | 7.2.2 | 314 | **success** | **first boot with `host_reset=1`** (flag removed from cmdline). Firmware had prebuilt the tunnel; the reset tore it down at 7.25 s (`pciehp Link Down`), router back at 7.52 s, PCIe `Link Up` at 18.3 s, `external GPU detected` at 19.65 s. **Rebuild cost ≈ 12 s**, not the ~58 s measured in August. Does not yet prove the reset rescues a `link=none` boot — needs a sample where firmware left the port in USB3 fallback. |
| Sep 3 (2nd) | 7.2.2 | 314 | **success** | `host_reset=1`, same shape: firmware-prebuilt tunnel reset at 7.37 s, `Link Up` 18.8 s, GPU 20.1 s, no Xid. Still no fallback sample. Note: 2/2 firmware-prebuilt on 314 vs. ~30% on 311 — small n, but consistent with the MPIO bump helping firmware-side link bring-up. |
| Sep 4 15:4x | **7.2.3** | 314 | **success** | First boot on a NEW kernel: the pacman hook rebuilt the patched modules in-transaction (39 s build, LLVM flags auto-detected), so the boot had a driver. Firmware-prebuilt tunnel reset at 7.13 s, `Link Up` 18.2 s, GPU 19.5 s, no Xid. External display lit on the greeter this time (the Sep 4 morning dark-greeter was a one-off so far). Tally with `host_reset` default: **3/3**. |
| Sep 5 | 7.2.3 | 314 | success, **late** | Experiment: `pcie_port_pm=off` REMOVED. Reset at 7.07 s, router 7.34 s — then root port `00:01.1` runtime-suspended (337.5 s in D3) and the PCIe tunnel only came up at **344.7 s, 3 s after login**; GPU at 347 s. No link drop afterwards (August symptom gone). Verdict: port PM must stay off for the two tunnel root ports — narrow udev pin adopted, pending validation. |
| Sep 5 (2nd) | 7.2.3 | 314 | **success** | `pcie_port_pm` default + udev pin on `00:01.1/.2`: reset 7.03 s, `Link Up` 18.22 s, GPU 19.55 s, login 90 s. `00:01.1` suspended 0 ms. **Pin validated; global flag retired.** Unaided cold boots with `host_reset` default: 5/5 (one late, explained). |
| Sep 5 (3rd) | 7.2.3 | 314 | **success** | First boot with **DPM=0 actually in effect** + GPU `power/control=on` pin. Enclosure came up on domain **1** (`1-2`, root port `00:01.2`, GPU `63:00.0` — cable moved to the laptop's other USB4 port), proving the udev pin covers both tunnel ports and the GPU rule follows the card; no firmware-prebuilt tunnel this time (no `Link Down`), kernel CM built it fresh: router 6.49 s, `Link Up` 17.16 s, GPU 18.73 s, login 34.5 s. 6/6. |
| Sep 5 16:49 | 7.2.3 | 314 | success | blackwell-egpu-manager test, root-port pin and DPM=0 file moved aside: `00:01.2` runtime-suspended at boot, tunnel `Link Up` ~30 s wall, GPU bound at +1 s, then the manager's udev rule detached the tree (clean, 0 Xid). Same shape 15:33 and 16:52 — 3/3 for the day, see the manager section. |

Keep adding rows. Two clean successes on 7.2.2/311 already look better than the old
~30%; whether 314 helps or hurts needs several uncontaminated boots.

**Failure fingerprint, sharpened (Sep 3):** on the failed boot the enclosure's *USB*
devices enumerated normally on the xHCI (`Razer Core X V2` HID at `usb 5-1.4`), Type-C
`port0` showed a partner sourcing power, and both host routers reported
`usb4_portN/link = none`. I.e. the cable came up as plain **USB 3.x fallback** — the
USB4 link itself was never negotiated, so there was no router to enumerate and nothing for
the PCI layer to see. This is the same shape as Framework's PI-regression report
("degrades from USB4 to USB3.2"). Diagnostic one-liner:
`for p in /sys/bus/thunderbolt/devices/*-0/usb4_port*; do echo $p $(cat $p/link); done`
→ `none` with the enclosure's USB gear visible in `lsusb` = USB3 fallback.

**Two distinct "no child router at cold boot" mechanisms are now catalogued** (both
invisible to PCI-layer udev rules, both look the same from `boltctl`):
1. **Intel (DamianKA1993, Tiger Lake, Sep 5):** the Thunderbolt root ports
   (`0000:00:07.*`) start runtime-suspended (D3), so the host controller never attempts
   the tunnel. Fix: runtime-resume them — `echo 1 > /sys/bus/pci/devices/0000:00:*/rescan`
   (a rescan runtime-resumes the bridge), then a global rescan. Diagnostic:
   `cat /sys/bus/pci/devices/0000:00:0*/power/runtime_status` → `suspended`.
2. **AMD GZ302EA (this machine):** root ports are never suspended (`pcie_port_pm=off`),
   both NHIs are bound, but the USB4 **link** was never negotiated — `usb4_port link=none`
   with the enclosure's USB gear enumerated (USB3 fallback). A rescan cannot fix this;
   only a host-router reset (`thunderbolt.host_reset` default) or a physical replug
   renegotiates the link. Diagnostic: the `usb4_port*/link` one-liner below.
Classify first, then pick the fix — the two are not interchangeable. Verified Sep 5 on the
GZ302EA: every `0000:00:*` device reports `runtime_status=active` with `power/control=on`
(`pcie_port_pm=off` in effect), so the Intel root-port wake loop is a guaranteed no-op
here — and its trailing bare `/sys/bus/pci/rescan` is the operation this runbook warns
about for stale tunnel devices (re-add without bridge-window resize → `BAR0 is 0M`).

**Hypothesis under test:** `thunderbolt.host_reset=0` makes the kernel *skip* the host
router reset at probe, so a port that firmware left in USB3 fallback is never
renegotiated. `host_reset=1` (the default) resets the router and re-runs link
negotiation — potentially a software fix for the cold-boot lottery at the cost of the
~58 s rebuild on boots where firmware had already built a tunnel.
**Cannot be tested at runtime:** `/sys/module/thunderbolt/parameters/host_reset` is
read-only (0444) and the module is pinned by `typec` (UCSI), so reloading it means
tearing down Type-C/PD management — not worth it. The test is a cmdline change:
drop `thunderbolt.host_reset=0` from `/etc/default/limine`, `sudo limine-update`, then
tally cold boots with the enclosure attached. Reversible; worst case is the ~58 s
tunnel rebuild on boots that would have worked anyway.

**Replug data point (Sep 3 13:31, BIOS 314):** physical replug on the failed boot →
`usb4_port2 link=usb4`, `thunderbolt 0-2: Razer Core X V2`, `external GPU detected`
3 s later, no Xid. Replug remains 100%.

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
thunderbolt.clx=0
pci=realloc=off
amdgpu.dcdebugmask=0x800
```
(Current as of Sep 5 2026 — `pcie_ports=native` removed Aug 26, `thunderbolt.host_reset=0`
removed Sep 3, `amdgpu.dcdebugmask=0x800` added Sep 4, `pcie_port_pm=off` removed Sep 5 with the
two USB4 tunnel root ports pinned awake by udev instead; see the bullets for why.)

- `amdgpu.dcdebugmask=0x800` — **DC_DISABLE_IPS (added Sep 4).** Not eGPU-related: fixes
  the AMD iGPU's external HDMI display staying dark after DPMS wake (DCN 3.5.1 IPS exit
  bug; 6/6 clean wakes at 4K120+HDR with it vs. reliable failure without). See the DPMS
  section. Bit from `enum DC_DEBUG_MASK` in amd_shared.h.

- `/etc/modprobe.d/99-amdgpu-hdmi-frl.conf` → `options amdgpu dcfeaturemask=0x402` —
  **HDMI 2.1 FRL re-enabled (added Sep 7).** Not eGPU-related. linux-cachyos 7.2.3 ships the
  upstream default `dcfeaturemask=2` (DC_FRL_MASK 0x400 off, because HDMI VRR is unfinished);
  7.2.0–7.2.2 had 0x402. With FRL off the laptop HDMI (a DP-HDMI FRL **PCON** — the flag
  gates that path too) silently ran 4K120 HDR as **8-bit YCbCr 4:2:0** (limited range,
  banding). With 0x402: **10-bit BT2020 RGB**. The file is baked into the initramfs by the
  `modconf` hook → `sudo limine-mkinitcpio` after editing. Verify live (root):
  `grep -A2 HDMI-A-1 /sys/kernel/debug/dri/1/state` for the crtc, then
  `dri/1/<crtc>/amdgpu_current_bpc` + `amdgpu_current_colorspace` (want `Current: 10`,
  `BT2020_RGB`). The connector-level `output_bpc`/`output_format` in the state dump are NOT
  live on amdgpu, and the `hdmi_frl_status_polling_workqueue` exists either way. Keep
  `HDMI-A-1` at `Vrr: Never` while this is forced. Drop the file once upstream flips the
  default back. Source: discuss.cachyos.org/t/35350.

- **Gen3 bridge cap + late NVIDIA load (added Sep 16)** — `tools/gen3-cap/`:
  `/etc/modprobe.d/zz-nvidia-egpu-lateload.conf` (blacklists nvidia* for udev autoload only),
  `/etc/udev/rules.d/99-nvidia-egpu-cap-and-load.rules`,
  `/etc/systemd/system/nvidia-egpu-cap-and-load.service`, `/usr/local/bin/nvidia-egpu-cap-and-load`
  and `/usr/local/bin/nvidia-egpu-unload`. On every GPU add: LnkCtl2 on the port above the GPU
  (`62:00.0`) = Gen3 + Hardware Autonomous Speed Disable, retrain, then modprobe; on GPU
  remove: unload so the boot-time tunnel rebuild is re-capped before the GSP boots. Refuses
  to retrain under a bound driver. Why: efenex on #979 — the JHL9480 port renegotiating
  speed under the GSP is the Xid-154 trigger; capped, his box is stable even on the stock
  driver. Verified here: Gen3 x4 at P0 under FurMark. Cost: none measurable (tunnel-bound).
  Cold boot only — never hot-plug. Status: `sudo nvidia-egpu-cap-and-load --status`;
  remove: `sudo bash tools/gen3-cap/install.sh --remove` + reboot.
  **Cost of FRL (Sep 7 23:15):** first-ever `amdgpu: enabling link 1 failed: 19` at a
  lock-screen wake with the lid closed. `dc_status` 19 = `DC_FAIL_HDMI_FRL_LINK_TRAINING`
  (core_status.h) — the FRL link training itself failed once (sink not ready ~7 s after the
  wake keypress) and DC never retried; the monitor stayed dark until the next modeset (a
  lid close/open 2 min later re-applied the layout). Never seen on the 4:2:0 TMDS link
  (journal total before this: 0). The Meta+Shift+D rescue is a global shortcut and may be
  blocked on the lock screen. **Workaround (not a fix):** user service
  `hdmi-link-retry.service` (`tools/hdmi-link-retry{,.service}`) follows the kernel journal
  and forces a modeset via `display-rescue` (KScreen over DBus, works while locked) **8 s**
  after that message (the monitor's own HPD pulse arrived at +8 s), up to 3 rounds per
  episode. Why no driver-side option: `enable_link_hdmi_frl()` retries only 3×200 ms,
  `link_set_dpms_on_enable_link()` then returns `DC_DPMS_SUCCESS` regardless ("some DP
  monitors will recover and show the stream"), so DRM/KWin see success; the SCDC polling
  worker that re-trains an established link is armed only on success; and
  `amdgpu_dm_debugfs.c` exposes no FRL knob (`trigger_hotplug` only re-detects). The fix is
  a few lines in `link_hdmi_frl.c` (longer wait when SCDC is unresponsive, or arm polling on
  failure). Validation of the workaround pending the next real occurrence.
  **Sep 8 — the same failure in two more places, and the workaround validated once:**
  (a) 11:17 lock-screen wake: `enabling link 1 failed: 19` again; `hdmi-link-retry` fired at
  +8 s (`retry 1/3`), the hotkey fired 35 s later too, both modesets reported success — and the
  monitor still stayed dark for minutes before lighting on its own with no logged trigger.
  (b) Boot with the folio closed: the greeter's lid-closed layout is correct (eDP off, LG
  enabled at its stored 3840x2160@120), it tried the FRL modeset, no error, no picture; the
  user session's modeset 9 s after login lit it. So the sharper description is: **the first
  FRL modeset after the monitor has been in standby can come up dark while DC reports
  success** (`hdmi_frl_poll_start` waits only 200 ms for the sink's FRL_START and proceeds
  regardless); a later modeset lights it. Workarounds now in place for both entry points:
  the retry service for in-session wakes, and `tools/greeter-hdmi-4k60.sh` pinning the
  greeter's LG entry to 3840x2160@60 SDR (TMDS, no FRL) — applied Sep 8, verify on the next
  lid-closed boot; the greeter's KWin rewrites that file, so check with
  `tools/kwin-outputconfig-dump.py` if it regresses. The monitor is an **LG TV (`LG TV
  SSCR2`) with no DDC/CI**, so PowerDevil's DDC backend has no value on this display.
  **Sep 10 00:13 — third instance, and a sibling upstream bug.** DPMS wake with the screen
  locked: no FRL failure logged at all; PowerDevil's ddcutil watcher saw the LG's EDID appear
  on **i2c-13 (a DP AUX bus)** at +2 s and move to **i2c-5 (HDMI DDC)** at +11 s — the PCON
  re-detected first in active FRL mode, then in HDMI passthrough — and the TV showed nothing
  through either. Six hotkey presses over 22 s eventually lit it. The rescue's 2 s off-time is
  the suspect: `display-rescue` now holds the output off for **8 s** and takes a lock so
  presses queue instead of overlapping (backup `~/.local/bin/display-rescue.bak-20260910`).
  Hypothesis, not proof: the TV needs a longer no-signal gap to reset its receiver after
  standby. Upstream sibling: **drm/amd #5757** ("[7.2.x – 780M] HDMI: no signal when display
  requests YCbCr 4:2:0", 780M + Samsung TV, works on 7.1 and 6.18 LTS, "the system thinks the
  display works", no AMD reply yet) — same shape (source reports success, sink dark) from the
  7.2 HDMI rework, different mode. Reddit r/cachyos "no signal after logging in" is an NVIDIA
  4070 Ti user, unrelated. **Decided (Sep 10 evening):** the 8 s rescue did not help either — at the
  20:34 wake the training failed once, the service's modeset and a hotkey modeset both
  "succeeded" per DC, and the TV stayed dark for minutes until it synced on its own. So the
  dark wake is the sink failing to lock onto the first FRL stream after standby; no host-side
  modeset timing fixes it. David chose to **keep FRL (10-bit RGB, 120 Hz) and live with it**:
  known behaviour, comes up eventually, hotkey optional. `hdmi-link-retry` service removed;
  the modprobe flag and the greeter 4K60 pin stay. Fallback if it ever becomes intolerable:
  delete `/etc/modprobe.d/99-amdgpu-hdmi-frl.conf` + `limine-mkinitcpio` (back to 4:2:0
  8-bit, which woke 6/6), or pick 4K60 in Display Settings for 8-bit RGB over TMDS.

- `pcie_port_pm=off` — was **required** in August: without it the PCIe link dropped ~1 s
  after the nvidia module loaded (`pciehp: Link Down` / `Card not present`).
  **Retested Sep 5 (removed, kernel 7.2.3 / BIOS 314):** that post-load drop did NOT
  recur — the link held. But a different problem appeared: after `host_reset` tears down
  firmware's tunnel at ~7 s, root port `00:01.1` has no child and runtime-suspends
  (`power/control=auto`); the PCIe tunnel then cannot come up until something wakes the
  port. Measured: `runtime_suspended_time` = 337.5 s, `Link Up` at 344.7 s = **3 s after
  login** (session start touched the bus). eGPU effectively absent until login. This is
  DamianKA1993's Intel root-port-D3 mechanism, reproduced on AMD once port PM is enabled.
  **Better fix than the global flag:** pin only the two USB4 tunnel root ports awake via
  udev (`ATTR{power/control}="on"` for `0000:00:01.1` and `0000:00:01.2`), leaving every
  other port on default runtime PM — see `99-usb4-tunnel-ports-awake.rules` (tools/).
  **VALIDATED Sep 5:** next cold boot with the rule and no flag — reset 7.03 s, `Link Up`
  18.22 s, GPU 19.55 s, login at 90 s; `00:01.1` runtime_suspended_time = 0 ms. Adopted.
  Caveat: the rule applies at udev coldplug, so an unused port can nap a few seconds first
  (`00:01.2` logged 6.4 s); worst case for `00:01.1` is a few seconds' delay, not
  "until login". Fallback remains restoring `pcie_port_pm=off`. Never adopt the Intel
  rescan loop here — its global bare rescan is the stale-device `BAR0 is 0M` hazard.
- `pcie_aspm.policy=performance` — minimizes ASPM transitions.
  **Never use `pcie_aspm=off`** on this AMD platform: it breaks the ACPI `_OSC` handoff
  (`OS requires [ExtendedConfig ASPM ClockPM MSI]`), the OS never takes PCIe ownership,
  and MSI-X allocation fails → `NVRM: Failed to enable MSI-X` → `RmInitAdapter failed! (0x22:0x56:894)`.
- `pci=realloc=off` — from a report with the identical Razer Core X V2. Replaced the earlier
  `pci=assign-busses,hpbussize=...,realloc`. An HPE advisory documents `pci=realloc` removing
  BIOS-assigned BARs without reassigning them.
- `thunderbolt.clx=0` — disables TB low-power lane states.
- `thunderbolt.host_reset=0` — **REMOVED Sep 3 2026 (default `=1` now in effect).**
  History: added in August to preserve firmware-prebuilt tunnels; an Aug 26 attempt to
  remove it never took, so it was never actually tested until now. Why it was removed:
  the cold-boot failure fingerprint is a port left in USB3 fallback (`usb4_port link=none`),
  and `=0` tells the kernel to skip the host-router reset that would renegotiate it. With
  the default `=1`, the first boot showed the reset tearing down firmware's tunnel at
  7.25 s and the GPU detected at 19.65 s — a **~12 s rebuild cost**, not the ~58 s measured
  in August (kernel 7.2.2 / BIOS 314 era). Whether it rescues a genuine fallback boot is
  still being tallied (see the cold-boot section). Revert = re-append `=0` + `limine-update`.
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

### 615.71.09 status (Sep 9) — the next-driver gate has opened, but only halfway

NVIDIA published `NVIDIA-Linux-x86_64-615.71.09.run` (packaged Sep 5; in `~/Downloads`). As
of Sep 9: Arch `extra` still ships `nvidia-utils 610.57.04-1` (nothing in `extra-testing`),
and `NVIDIA/open-gpu-kernel-modules` has **no 615 tag yet** (latest 610.57.04). Do NOT run the
`.run` on this system: it would replace pacman's userspace, install unpatched modules outside
the hook, and it ships the RM only as `nv-kernel.o_binary` — the `src/nvidia` tree our E1/C3/C5
patches modify is not in it. Wait for both the Arch package and the GitHub tag.

**Pre-check done from the `.run`'s `kernel-open/` tree** (`sh ... --extract-only`, then
`git apply --check --include='kernel-open/*'` per patch; RM-side hunks not checkable yet):

| Patch | kernel-open hunks vs 615 | Notes |
|---|---|---|
| 01 E1 egpu-detection | apply clean | RM hunks (`osinit.c`, `os-interface.h`) pending tag |
| 02 C2 AER unmask | **fail** at `nv-pci.c:1759` | context drift only — see below |
| 03 C3 gpu-lost retry | n/a (RM-only) | pending tag |
| 04 C4 err-handlers scaffold | **fail** at `nv-pci.c:2810` | context drift only |
| 05 C6 rwlock fix | apply clean | `os-interface.c` changed 367 lines but not there |
| 06 C5 crash-safety | **fail** in `nv.h`, `os-interface.h`, `nv-pci.c`, `os-pci.c` | plus ~30 RM files pending tag |

`nv-pci.c` changed by ~1070 lines between 610.57.04 and 615.71.09, but **none of it is error
handling**: no new `pci_error_handlers`/AER/`slot_reset`/hotplug code (keyword counts
unchanged); the additions are Tegra devfreq plumbing and `nv_pci_wait_for_probe_complete()`.
So C2 and C4 are not obsoleted upstream — they need re-basing, not rethinking. `drm_dev_unplug`
in `nvidia-drm-drv.c` was already present in 610; NVIDIA added no lost-GPU teardown, so C5's
G10 path is still the only one. Changelog items worth a look at test time: "Fixed a bug that
could cause corruption when display output scaling is used on Blackwell GPUs" (possible
relevance to the eGPU-display Xid 56 sparkles — retest the ladder), the new
`RmDisableDisplayGlitchPerfLimit` registry token (memory-clock switching while display is
using memory — leave off; our lock pins mclk anyway), and PR #1199 (resume after hibernate).

**Port done (Sep 10):** NVIDIA tagged `615.71.09` on GitHub and CachyOS shipped
`nvidia-utils 615.71.09-1` the same day (Arch extra still 610). All six patches are re-based on
a separate worktree `~/open-gpu-kernel-modules-615` (branch `egpu-615.71.09`, 6 commits on the
tag) and exported to `patches-615.71.09/` in this repo with port notes; the set applies in
sequence on a pristine tag and **builds clean** for `7.2.3-1-cachyos` with the hook's Clang
flags (39 s, 0 errors, modinfo 615.71.09). Not runtime-tested yet.

**Switch-over is now automatic (hook v2, Sep 10).** `nvidia-egpu-rebuild` ports the tree
itself when `nvidia-utils` changes: finds `patches-<ver>/` in the repo (pulls the repo if
missing), fetches the tag, `checkout -B egpu-<ver>-auto`, applies, commits, builds, installs —
all inside the pacman transaction, before the reboot. Tested end-to-end with
`--utils 615.71.09 --no-install` on a scratch worktree (6/6 applied, built 615.71.09 in 39 s);
missing-tag case fails cleanly with the tree untouched; no-patch-set case builds the pristine
tag with a loud warning (`FALLBACK_UNPATCHED=yes`). Two real bugs found by the test and fixed:
the config is sourced by shell and paths with spaces broke it (values now quoted by
install-hook.sh), and `-d .git` rejected git worktrees (now `git rev-parse --git-dir`).

Procedure for this machine:
1. Re-install the hook once so the config gains `PATCHES=` and quoted values:
   `sudo bash pacman-hook/install-hook.sh` (keeps `TREE=~/open-gpu-kernel-modules`).
2. Preview: `sudo nvidia-egpu-rebuild --check --utils 615.71.09`.
3. Kernel first, driver second (so a failure is attributable): `sudo pacman -Syu --ignore nvidia-utils,lib32-nvidia-utils,opencl-nvidia,lib32-opencl-nvidia,nvidia-settings,libxnvctrl`, reboot, confirm the eGPU on 610.
4. Then a plain `sudo pacman -Syu`: nvidia-utils → 615.71.09, the hook ports and builds in-transaction (`/var/log/nvidia-egpu-rebuild.log`), reboot with the enclosure attached.
5. Verify: `nvidia-smi` 615.71.09, `/proc/driver/nvidia/params` DPM=0, `external GPU detected`, a game, then the display ladder rung 1080p60 (and one 4K60 retry, clocks locked — the 615 changelog has a Blackwell display-scaling corruption fix).
6. Rollback: `sudo pacman -U /var/cache/pacman/pkg/nvidia-utils-610.57.04-3-*.pkg.tar.zst` + the lib32/opencl/settings siblings; the hook then auto-ports back to 610 (patches/VERSION = 610.57.04), reboot.
The separate worktree `~/open-gpu-kernel-modules-615` is now just the reference port; it can be
removed after the real switch succeeds.
**First real run (Sep 10 16:5x) FAILED, my bug:** the hook's log was `/tmp/nvidia-egpu-rebuild.log`;
my non-root tests had created that file as `davidj`, and with `fs.protected_regular=1` root
cannot append to another user's file in sticky `/tmp`, so every `2>>$LOG` redirect failed and
bash skipped the commands behind them (fetch, checkout) → "git checkout failed". Tree was left
untouched (good), but the transaction had already replaced the userspace with 615 and removed
the 7.2.3 module directory, so the system was one reboot away from a driverless kernel. Fixed:
root logs to `/var/log/nvidia-egpu-rebuild.log`, non-root to `$XDG_RUNTIME_DIR/…-<uid>.log`.
Recovery = reinstall hook (install-hook.sh) and run `sudo nvidia-egpu-rebuild` before rebooting.
Done at 16:5x: the real hook run ported and built 615.71.09 for 7.2.4 in 40 s.

**First boot on 615.71.09 (Sep 10 16:59) — GSP death at +18 s, then a hard reset.**
Journal (boot -1): 16:59:42 the usual host_reset tunnel teardown; 16:59:53 pciehp Link Up,
GPU re-enumerated, `AER: unmasked … at probe` (C2 alive), `external GPU detected` (E1 alive),
`NVRM: loading … 615.71.09`. 17:00:11, card idle at the greeter: `GspMsgQueueReceiveStatus:
Incorrect message length 6/0`, `Read failed after 3 retries`, every RPC status 0x3a
(GSP_RM_CONTROL/ALLOC from the greeter's KWin allocating VA spaces), then C5's detector:
`cleanupGpuLostStateAtomic: GPU 0 lost via detector_class=0` + `Xid 154 … PF FLR`. **No
IOMMU faults, no link/pciehp events** after the probe: the tunnel stayed up; the GSP died on
its own. Same class as the 610 losses (Sep 5 under load, Sep 8 at lock). The RPC/GSP hunks of
C5 are byte-identical between the 610 and 615 trees, and boot 2 on 615 is clean (0 Xid,
P8, Gen4 x4) — so not a port defect, one more sample of the known GSP-death class.
**New and worse:** 17:00:21 David logged in (greeter session exited normally); the user
session's KWin started with the dead NVIDIA DRM device still present (no `Removing device`
ran — soft loss, device on bus); 17:01:07 `amdgpu: Fence fallback timer expired on ring
gfx_0.0.0 / sdma0` → black screen; 17:01:09 last journal line, then a **hard reset with no
shutdown or panic text** (kernel.panic=0, nowatchdog; journald likely lost the final
seconds). Hypothesis: the new compositor blocked on a dma-fence from the dead GPU and the
iGPU's rings starved; on Sep 8 (610) the same loss did NOT hang amdgpu because KWin was
already running. Check `/sys/fs/pstore` (root) for a panic record. Verdict so far: 615 +
ported patches work (E1/C2/C5 all visibly active); whether 615 changes the GSP-death rate
needs days of samples (610: ~2 in 5 days).

**Pin declined (Sep 9):** David prefers not to add standing customisations that can bite
later; he watches the `-Syu` package list for `nvidia-utils` and stops before confirming the
upgrade. If an update ever does slip through, the symptom is the hook refusing the build and
`nvidia-smi` failing after reboot; recovery is `pacman -U` the cached 610.57.04 packages from
`/var/cache/pacman/pkg/` (or the port). The pin, if ever wanted:
```
IgnorePkg = nvidia-utils lib32-nvidia-utils opencl-nvidia lib32-opencl-nvidia nvidia-settings
```
in `/etc/pacman.conf`. Lift it deliberately when the tag exists and the six patches are
re-based and `git apply --check` clean against it. Then run the standing plan: stock 615 vs
patched 615 under DPM=0 (launch gauntlet + display ladder), decide with data.

### Never install nvidia-open-dkms

It builds an **unpatched** module into `/lib/modules/$(uname -r)/updates/dkms/`, which takes
precedence over `kernel/drivers/video/`. Your patched module is silently shadowed.

```bash
pacman -Q | grep dkms
ls /lib/modules/$(uname -r)/updates/dkms/ 2>/dev/null
```

---

## Hard bus drop during 3D development (Sep 16 15:11) — KWin oops in nvidia_modeset, journal flooded

Boot of 13:48 (615.71.09 + Gen3 cap active, Gen3 x4 confirmed). At 15:11:45, while David
was doing 3D software development (Vulkan app iterations), the **whole enclosure tree left
the bus** (`pci_bus 0000:62..c0: busn_res released`, `GPU lost from the bus`, PMC_BOOT_0 reads
`0xffffffff`) — a hard loss / surprise removal, NOT the GSP-death class the Gen3 cap targets.
Consequences, in order:
1. **Journal flood:** 23,026 × `_intrServiceStallCommonCheckBegin: Failed GPU reg read` and
   13,296 × `GPU lost from the bus` inside ONE second (interrupt service loop on a dead
   device). journald rotated five 6.5 MB files at 15:11 and **everything before 15:11:45 in
   that boot is gone** — including whatever triggered the drop. The print at
   `intr.c:141/1567` is not covered by C5's `NV_GPU_LOST_LOG_ONCE`.
2. **kwin_wayland (PID 2198) took a kernel general protection fault** at
   `nvkms_ioctl_from_kapi+0x7b` ← `nvKmsKapiReleaseOwnership` ← `nv_drm_master_drop` ←
   `drm_master_release` ← `drm_release` ← `close()`. KWin closed its DRM fd on the removed
   card; nvidia-drm's `master_drop` still calls into NVKMS for a device that no longer
   exists. C5's G10 guard covers the device-remove teardown (`nv_drm_remove`) but **not the
   master-drop path** — even though 615's `nv_drm_remove()` calls `drm_dev_unplug()` first,
   `nv_drm_master_drop()` never checks `drm_dev_is_unplugged()`. The oops killed the
   compositor → black screen → reboot at 15:20.
3. The cap's unload twin could not unload (modules held by PID 46554, the 3D app); the GPU
   re-enumerated 3 s later and bound **uncapped** (the script correctly refused to retrain
   under the bound driver). Design consequence: after any drop with a live holder the
   session runs at Gen4 until the next cold boot.
**Trigger (David): launching a 3D game** — the P8→P0 ramp, which on this link is also the
Gen1→Gen3 retrain (idle sits at Gen1, `--status` showed it). Hypothesis, not proven: the drop
*is* that retrain. Two responses, both applied the same evening:
1. `tools/gen3-cap` now also writes Target=Gen3 + HASD on the **GPU's** LnkCtl2 (not just the
   bridge), asking the endpoint not to change speed autonomously, so the link should sit at
   Gen3 across P-states and a launch has nothing to retrain. RM may override it; check
   `sudo nvidia-egpu-cap-and-load --status` at idle after the next cold boot — Gen3 means
   honoured, Gen1 means overridden; either is safe.
2. **C7 applied** as `patches-615.71.09/07-C7-surprise-removal-unplug-guard-and-log-once.patch`
   (committed on the hook's `egpu-615.71.09-auto` branch, build-verified 0 errors, installed
   with the new `sudo nvidia-egpu-rebuild --force`): (a) `drm_dev_is_unplugged()` early-return
   in `__nv_drm_master_set()` / `nv_drm_master_drop()` — stops the compositor dying when the
   card is yanked; (b) the two `intr.c` "Failed GPU reg read" prints and the two
   `NV_ASSERT_OK_OR_ELSE` on `_intrServiceStallCommonCheckBegin` become `NV_GPU_LOST_LOG_ONCE`
   + silent return on `NV_ERR_GPU_IS_LOST`, so a surprise removal cannot erase the journal.
   Neither has been exercised by a real drop yet. The trigger of the drop itself stays
   unproven until a drop survives with its preceding seconds intact — (b) makes that possible.

**Cold boot 23:37 (Sep 16) with both changes:** cap log shows both writes (`62:00.0 0044→0063`,
`63:00.0 0005→0023`), retrain to Gen3 x4, driver loaded 23:46:29 (build stamp 11:26 PM =
the C7 build; the C7 strings are in the installed `nvidia.ko`). `--status` at idle, driver
bound, P8: bridge and GPU **Gen3 x4, hasd=1** — the GPU honoured the pin, the link no longer
downshifts to Gen1 at idle. `nvidia-smi` gen.current 3 / max 3. No Xid in the boot. Since the
launch-time retrain no longer exists, the hypothesis is now testable the other way: if the
drop still happens at game launch, the retrain was not the cause.
Note: this boot's journal begins at 15:11:45 only because of the flood; the cap
validation lines from 13:48 survived only because they were captured in this runbook.

## GPU loss observed through a DDC/CI brightness probe (Sep 8) — probe NOT the cause

11:17:46 lock screen → DPMS off. 11:17:47: PowerDevil's libddcutil `watch_displays` thread ran
an i2c transaction on one of the eGPU's five i2c adapters (`NVIDIA i2c adapter 2..6 at
63:00.0`, the card's empty physical connectors). On the open driver that is an RM control RPC
to the GSP (`rm_i2c_transfer → rmapiControl → _issueRpcAndWait`, stack in the journal); it
never returned, PTIMER read `ffffffff`, heartbeat timed out → **Xid 154, GPU lost**. No
pciehp/thunderbolt/AER event at that instant; config space still answered `10de` → soft loss.
The RPC history before the hang is 100% that thread's i2c controls. No monitor was on the
eGPU. First event of this kind in the persisted journal. Collateral: KWin `atomic commit
failed`, then the amdgpu HDMI FRL wake failure 8 s later (separate mechanism, see the FRL
notes). A udev mitigation was tried and then removed once the hypothesis failed (see below).
Recovery for this loss: KWin holds the dead card's DRM node → reboot-both-sides.
**Reproduction attempts (Sep 8 13:xx, eGPU healthy):** `sudo i2cdetect -y 24..28` — all five
NVIDIA adapters scanned (~120 transactions each through the same `rm_i2c_transfer → GSP RPC`
path), and `kscreen-doctor --dpms off; sleep 1; i2cdetect -y 24` to mimic the lock-screen
ordering: **0 Xid, GPU fine every time.** So the i2c probe is not sufficient to hang the GSP,
alone or during a DPMS-off. Reclassified: the 11:17 event is a GSP death of the known Xid 154
class in which an i2c RPC happened to be the request in flight — the probe is the witness,
not the trigger. The udev rule (`61-ddcutil-skip-egpu-i2c.rules`) was **removed the same day** at
David's request — a hardware-specific rule guarding a non-cause is a future trap. Standing state
is stock ddcutil access to all i2c buses. Nothing to post from this.

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
  ~18 Gbps link). **Caveat (Sep 7):** that was true on 7.2.0–7.2.2; on 7.2.3 the driver
  default dropped FRL and the same mode silently became 8-bit 4:2:0 until
  `dcfeaturemask=0x402` was set (see Current configuration). The Sep 4 DPMS 6/6 wakes were
  measured on the 4:2:0 link — re-validated Sep 7 with `tools/dpms-cycle.sh` at full FRL: 5/5.
  The certified 48 Gbps **10-foot** cable was *less* stable — it advertised
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
- NVIDIA developer forum, "RTX 5060 Ti eGPU Thunderbolt 4 CUDA hard-lock / GSP firmware
  hang" (DamianKA1993, Intel ThinkPad TB4 + AORUS AI BOX, 610.43.03): `kfspWaitForResponse:
  FSP command timed out`, no Xid. His eventual working config there = `setpci` LnkCtl2
  target-speed lock on the bridge before driver load **plus** `pcie_port_pm=off
  pcie_aspm.policy=performance thunderbolt.clx=0` (the flags this runbook runs) and
  `iommu=off` (do NOT copy — it removes DMA protection for a device on an external cable).
  His named mechanism, bridge speed oscillating Gen3↔Gen4 until GSP locks, is the #1229
  link-renegotiation class; the clock lock here attacks it from the GPU side, his setpci
  from the bridge side (virtualized/no-op registers on this tunnel). No NVIDIA reply.

Author's own framing: **a mitigation, not a fix.** Behaviour still varies by host.

**#979 developments read Sep 16:** (a) elvetemedve (Intel Meteor Lake + AORUS 5060 Ti
box) dropped `pcie_aspm.policy=performance` and `pcie_port_pm=off` — Damian's manager still
works; only `pci=realloc` is required for him (without it: `bridge window … can't assign; no
space`, the same two-phase sizing we hit). So on his host the active ingredient is the
manager's deferred attach + setpci ASPM/L1SS clear + retrain, not the flags. (b) **efenex
(Arrow Lake-HX, Minisforum MS-02 Ultra, JHL9580 host + JHL9480 AORUS 5090 box):** hard-lock
on first CUDA allocation with every combination he tried — until he **capped the bridge above
the GPU at Gen3 with Hardware Autonomous Speed Disable (LnkCtl2 target speed = Gen3 + bit 5),
retrained, and only then loaded nvidia** (driver blacklisted at boot, loaded by a script/systemd
unit). Then: 8 boots, 387 GB verified H2D/D2H at ~3 GB/s, 2 min FP16 matmul at 575 W, 24 GiB
allocation, 0 Xid/AER. **Also works with STOCK 610.57.04, no patches** (6 boots Ubuntu 7.0 +
4 boots CachyOS 7.2.3, same soak). His words: "on this hardware the bridge cap is what
mattered, not the driver patches" (stock-without-cap untested). He also reports
**615.71.09 oopsed at module load** on his Intel box (ours loads fine on AMD). Intel-only
wrinkles: `thunderbolt.host_reset=false` broke JHL9580 probe → `module_blacklist=thunderbolt`.
**Implication for this host (untested):** our remaining failure is the idle GSP death
(Xid 154, ~2 per 5 days on 610, 1 so far on 615). It is in the #1229 link-renegotiation
class that a Gen3 cap on `62:00.0` would address from the bridge side (our clock lock
addressed it from the GPU side). Gen3 x4 costs almost nothing here: the tunnel already tops
out ~3.86 GB/s bulk. Cost is a late-load arrangement (nvidia must not bind before the cap).
**Adopted Sep 16 (David's call) — `tools/gen3-cap/`.** Mechanism on this host: nvidia is
blacklisted for udev autoload; a udev rule on the GPU's PCI add starts
`nvidia-egpu-cap-and-load.service`, which writes LnkCtl2 (Target Link Speed = Gen3, HASD) on
the port above the GPU (`62:00.0`), retrains, waits for DL-active at ≤Gen3, then
`modprobe -a nvidia nvidia_uvm nvidia_modeset nvidia_drm`. Because this host enumerates the
GPU twice per boot (firmware tunnel, then the host-reset rebuild ~20–30 s), a twin
`nvidia-egpu-unload` runs on the GPU's remove so the second add finds no driver loaded — a
loaded driver binds in-kernel before udev can cap, and the script refuses to retrain under a
bound driver. Cold boot only, no hot-plug. Scope: that one port + the nvidia modules.
**Validated on the first cold boot (Sep 16 13:48):** the firmware-enumerated GPU was already
torn down when udev replayed its add (service: "no NVIDIA GPU on the bus"); at the rebuild
(+9 s) the GPU arrived with `driver=none` (blacklist held), LnkCtl2 `0044 → 0063`, retrain
settled at **Gen3 x4** on bridge and GPU, then the four modules loaded and bound. At idle the
link sits at Gen1 (P8 downclock, same as before); **under FurMark: P0, Gen3 x4** (was Gen4).
Then the real measure is Xid-154 frequency over the following weeks (610: ~2 in 5 days;
615: 1 on the first boot). Rollback: `sudo bash tools/gen3-cap/install.sh --remove` + reboot.

**Patch-free counterexample (DamianKA1993, Sep 1):** the same JHL9480 bridge
(`HotPlug- Surprise+`), stock `nvidia-open` DKMS, zero kernel cmdline flags, zero
modprobe blacklists — stable on his Ryzen mini PC + AORUS 5060 Ti AI BOX, carried by
userspace alone: `NVreg_DynamicPowerManagement=0` at modprobe + P0 clock locks + his
udev attach-gating. So the patch set is not *universally* required on this bridge.
What does NOT transfer to the GZ302EA without retesting: (a) "zero kernel flags" —
`pcie_port_pm=off` was proven required here (link drops ~1 s after module load without
it). **This is a HOST-PLATFORM difference, not an enclosure one** (correction Sep 3):
both enclosures are self-powered mains devices that deliver USB-PD *upstream* to the
host — the Core X V2 supplies up to 100 W to the Z13, just as his AORUS does to his mini
PC. Neither draws bus power from the host, so the flag requirement is about how the
GZ302EA / Strix Halo laptop power-manages its own PCIe ports, not about enclosure power
topology. (An earlier "self-powered vs host-powered" framing was wrong.)
(b) his udev settling/gating operates at the PCI layer and cannot touch this
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

## blackwell-egpu-manager v1.5.5 tested on this host (Sep 5)

DamianKA1993 asked for an out-of-the-box test on other hardware. Done snapshot-protected
on the live install (snapper + limine-snapper-sync) rather than a fresh CachyOS, with our
DPM=0 modprobe file and the root-port udev pin moved aside, patches and cmdline left in
place and disclosed. Full timestamped notes: `docs/blackwell-egpu-manager-test-2026-09-05.md`;
helpers in `tools/manager-test/`. Summary:

- **Its udev rule does not gate attach here.** nvidia autoloads by modalias; the tunnel
  rebuilds ~30 s into boot; the driver binds and boots GSP; the rule PCI-removes the
  5786 tree ~2 s later. Teardown was orderly (gpuLost=false) on 3/3 cold boots, 0 Xid, so
  the intended Mode 2 end state is reached — but as a post-init detach, not a pre-attach
  block. On an Intel host stuck in `kgspInitRm` the remove would land on a hung probe.
- **Mode 3 as shipped failed** (`NVRM: BAR0 is 0M @ 0x0`). Journal: two-phase enumeration.
  Its root-port rescan sizes the switch windows while the GPU port (62:00.0, `HotPlug-`)
  link is still down → 6 MB for three empty ports; the GPU appears moments later needing
  ~640 MB → every BAR "can't assign; no space". Not the driver, not its setpci work, and
  not `pci=realloc=off`: a full pass with the GPU present sizes correctly under it.
- **Working attach (3/3):** after the rescan check `/sys/bus/pci/devices/<gpu>/resource`
  line 1; if BAR0 is 0, remove the 5786 upstream port, wait ~8 s (link retrains 3–5 s
  after re-enable; poll `setpci CAP_EXP+12.w` bit 13), rescan the root port again.
  Timing-dependent: 1 of 3 immediate rescans happened to work (22 s after the detach).
- **`fuser -k /dev/nvidia*` in set3 SIGKILLed kwin_wayland.** KWin holds `/dev/nvidiactl`
  whenever the module is loaded, GPU present or not. Plasma 6 respawned it; every Wayland
  client that could not reconnect died. Reported.
- **Its DPM=0x00 modprobe was a no-op:** udev autoload had already loaded the module with
  the distro default (2) during the rescan. Same trap as our own Sep 5 finding, different
  route. Verify with `/proc/driver/nvidia/params`, always.
- **Load:** ~50 min game with its clock lock (DPM=2 in effect), 0 Xid — consistent with
  the lock-under-DPM=2 gauntlet above.
- **Mode 6 safe detach: clean.** Software PCI removal of a GPU the compositor had open
  did NOT freeze the display (contrast: the Sep 2 cable-pull freeze). KWin, plasmashell,
  Xwayland kept their PIDs. Leftover: the HDA function 63:00.1 stays bound to
  snd_hda_intel (only the VGA function is removed) — likely his known audio issue.
  Caveat: the removal ran through the patched teardown path (C5), so this does not prove
  a stock driver unwinds identically.
- Mode 4 not tested (removes the 8060S = the only panel path). Never press it here.
- Side observation: with the root-port pin absent, `00:01.2` was runtime-suspended at
  boot and the tunnel came up at ~30–35 s uptime on all three boots vs ~18 s with the pin
  (n=3, same kernel/BIOS) — consistent with the pin's purpose, not proof.

Net for this host: the manager's working ingredients reduce to ASPM/L1SS off, locked
clocks, and DPM=0 actually in effect — the same set already adopted here. Its value is
the attach/detach state machine, and Mode 6 is genuinely useful; Mode 3 needs the BAR0
check and the compositor guard before it is safe on KDE Wayland hosts that autoload
nvidia. Config restored and the manager uninstalled afterwards (snapshot kept).

## Open items as of Aug 26 evening

**Standing plan (Sep 5):** configuration is stable and frozen — DPM=0 verified, udev pin
for tunnel ports + GPU, IPS disabled, `host_reset` default, patches in, hook maintaining
them. The patches are not harming anything; the open question "are they still necessary
under DPM=0?" is deferred to the **next NVIDIA driver release**, when the patches must be
ported anyway (the hook will refuse the build until they are). At that point run the stock
vs. patched launch gauntlet under DPM=0 and decide with data. Display-from-eGPU is now
characterised (Sep 6): 1080p60 SDR is stable (12 min soak, usable daily); 4K60 lights
cleanly but hard-freezes ~5 min into load, so the limit is sustained scanout stability, not
bandwidth. Remaining lead for pushing 4K:
NVIDIA/open-gpu-kernel-modules#1229's reporter drives a Plasma Wayland desktop from a 5090
in the same Core X V2 on the same GZ302EA (610.43.02, kernel 7.0.13, NixOS) — so it is
not impossible on this host; differences to probe at the next driver release are driver
version (610.43 vs 610.57), GPU (GB202 vs GB203), and output mode.

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
5. ~~**Audit before installing** blackwell-egpu-manager~~ — DONE Sep 5: audited and
   tested v1.5.5 snapshot-protected, see the section above. Its udev rule cannot gate
   attach on this host (driver autoloads first); Mode 3 needs a BAR0 check and a
   compositor guard; Mode 6 works. Findings reported to the author. Mode 4 still never.
6. ~~**S5 poweroff test** with the eGPU cable fully detached~~ — SUPERSEDED: S5
   poweroff fixed by kernel update (7.2.2), see the Unresolved section. Follow-up
   worth watching instead: whether the same kernel range changed the **cold-boot
   tunnel lottery** — the watched fix ("thunderbolt: Fix PCIe device enumeration
   with delayed rescan") may have landed in this window. Track cold-boot success
   rate on ≥7.2.2 before concluding the ~70% failure figure still holds.
7. **Persistent journal** is worth enabling for future crashes:
   `sudo mkdir -p /var/log/journal && sudo systemd-tmpfiles --create --prefix /var/log/journal && sudo systemctl restart systemd-journald`
   Then `journalctl -b -1 -k` reads the previous boot after a hard crash.

## Sep 19 — HDMI FRL: why 4K60 wakes reliably and 4K120 does not (kernel 7.2.6 source)

David's observation: after DPMS the LG C2 comes back "pretty consistent" at 4K60 and fails
"pretty regular" at 4K120. Checked against the 7.2 amdgpu display code, not guessed:

- **The EDID is fine.** The C2 declares 4K120/100 as plain CTA VICs 118/117/219/218 at
  1188 MHz, one CTA block, no DisplayID; the kernel's mode list carries exactly the CTA
  timing (4400x2250 @ 1188000 kHz). The drm_edid.c quirk table has LG entries only for the
  27GP950/27GN950 (DSC bitrate cap), nothing for GSM 49352. An EDID override (the Samsung
  G80SD trick) has nothing to fix here.
- **The rate is what differs.** `hdmi_frl_decide_link_settings()` picks the *lowest* FRL
  rate that carries the timing, stepping up from 3G x3. 4K60 10-bit ≈ 17.8 Gbit/s → 6G x4;
  4K120 10-bit RGB ≈ 35.6 Gbit/s → 10G x4 (8G x4 = 32 is too small). So "60 works, 120
  fails" is "6 Gbit/lane trains after wake, 10 Gbit/lane does not".
- **The DPMS-on path never steps down.** `enable_link_hdmi_frl()` calls
  `hdmi_frl_perform_link_training_with_retries()`: same rate, up to 4 attempts 200 ms apart,
  then gives up (and `link_set_dpms_on` still reports success — the earlier finding). The
  rate-stepping variant `..._with_fallback()` is used only at detection
  (`hdmi_frl_verify_link_cap`). A "sink requesting lower link rate" reply also ends the loop
  without a retry at a lower rate.
- **No userspace knob.** `dc->debug.max_frl_rate / force_frl_rate / force_frl_dsc` exist but
  are set only from per-ASIC defaults; not a module parameter, not in debugfs. The per-panel
  quirk table (`apply_edid_quirks()` in amdgpu_dm_helpers.c) can set
  `panel_patch.delay_hdmi_link_training`, but link_dpms.c applies it only when
  `pix_clk_100hz == 6627500` (one specific panel's mode), so it is not usable as-is.
- **Which failure it is decides the fix.** The training log is drm_dbg() (silent by default).
  `tools/hdmi-frl-lt-capture.sh` turns the driver debug class on for one DPMS cycle and
  summarises: `FLT_READY not set` = the TV's receiver is slow to wake (a delay before LT, or
  a retry after the TV is up, fixes it — that is what the removed hdmi-link-retry service
  did); `Timeout waiting for FLT_UPDATE` = lanes never lock at 10G (cable / PCON / TV input
  signal quality — a certified 48G cable is the first thing to check); `lower link rate` =
  the TV refuses 10G after wake. Not captured yet.
- 7.4 candidates: the "restore FRL cap on non-destructive HDMI link verify" patch is a
  hotplug TMDS-fallback fix, not this. The "FRL LT timeout behaviour" change (Aug 10 DC
  series) is the only one whose description fits; text not yet read.

### Sep 19 19:22 — captured: the 4K120 failure is the driver's FLT_update budget, not the TV, not the cable

Two runs of `tools/hdmi-frl-lt-capture.sh` (logs in `docs/logs/frl-lt-4k{60,120}-2026-09-19.log`):

| mode | rate written | FLT_READY | sink's LTP request (poll #) | lock | result |
|---|---|---|---|---|---|
| 4K60 10-bit | 3 (6G x4) | poll 1 | poll 11 (21 ms after rate write) | poll 100, 179 ms after the request | PASSED 1st try |
| 4K120 10-bit RGB, try 1 | 5 (10G x4) | poll 1 | poll 22 (44 ms) | — | **FAILED at poll 105** (211 ms) |
| 4K120, try 2 (200 ms later) | 5 (10G x4) | poll 1 | poll 11 (21 ms) | poll 101, 181 ms after the request | PASSED |

Reading (from `hdmi_frl_perform_link_training()` in link_hdmi_frl.c, 7.2):
- The TV is awake: FLT_READY answers on the first poll every time. Not a slow-wake problem.
- The TV needs a steady **~180 ms** after it asks for the training patterns (LTP 5/6/7/8 on
  all four lanes) before it reports lock, at 6G and at 10G alike. Not a signal-quality
  problem either — the one 10G attempt that got its request in early locked fine.
- The driver's budget is **`max_polls = 105` × `wait_time_ns = 2 ms` ≈ 210 ms, started once at
  the rate write and never restarted**: the wait for the TV's LTP request and the wait for
  lock share it. 21 ms + 180 ms fits; 44 ms + 180 ms does not. At 10G the TV takes longer to
  produce its LTP request (44 vs 21 ms here), so the 120 Hz mode falls over the edge and the
  60 Hz mode does not. That is the whole difference between "60 pretty consistent" and
  "120 pretty regular".
- In this run the 200 ms retry saved it (try 2 passed). Real DPMS wakes that stay dark are the
  cases where all four tries land on the wrong side of the edge.

Fix candidates:
1. **Driver (the real fix):** a longer budget at 10G/12G. Intel's independent FRL
   implementation (i915 "Enable HDMI FRL for MTL+", Aug 2026, patch 14/44) also runs LTS:3
   on one 200 ms budget, so a per-event restart is not the agreed spec reading — but AMD's
   own 7.4 patch (below) already relaxes the budget to ~300 ms for ≥ 16 Gbps, and this TV
   needs ~225 ms at 10G. Extending that relaxation to ≥ 10 Gbps (`max_polls = 155` for
   `frl_link_rate >= HDMI_FRL_LINK_RATE_10GBPS`) is a one-line change to `link_hdmi_frl.c`
   with these two logs as the justification; worth sending to amd-gfx. Not built or tested.
2. **7.4 does not cover this.** The "Update and revert FRL LT Timeout behaviour" patch
   (Tom Chung / Relja Vojvodic, DC patches Aug 10, in the 7.4 pull) raises `max_polls` to 155
   (~300 ms) **only for link rates ≥ 16 Gbps** (HDMI 2.2 rates). 10G x4 keeps 105.
3. **Workarounds without a custom kernel:** (a) stay at 4K60 (6G x4) for reliable wakes, which
   is the current setting; (b) a modeset retry after a dark wake (the removed hdmi-link-retry
   service, or the Meta+Shift+D rescue); (c) 4K120 8-bit RGB is 28.5 Gbit/s → 8G x4, untested
   whether the TV's LTP request comes faster at 8G.

### Sep 19 20:15 — fix built, installed as a module override, verified 5/5 at 4K120

`kernel-patches/0001-drm-amd-display-Allow-300-ms-for-HDMI-FRL-link-train.patch` (LTS:3
budget 105 → 155 polls, ~300 ms, every rate) built in 68 s with
`tools/amdgpu-frl-module/build.sh` (srctree = CachyOS 7.2.6-1 source, O= a copy of the
installed headers tree, LLVM=1; vermagic and module BTF match the running kernel — the headers
package ships the real vmlinux, whose BTF is byte-identical to /sys/kernel/btf/vmlinux),
installed to `/usr/lib/modules/7.2.6-1-cachyos/updates/amdgpu-frl-lt/amdgpu.ko`, initramfs
rebuilt, reboot 20:15. `modinfo -n amdgpu` → the override; kernel logs the expected
unsigned-module taint.

Five DPMS cycles at 4K120 10-bit RGB (10G x4), logs in `docs/logs/frl-lt-4k120-fixed-*.log`:

| run | LTP request at poll | lock at poll | result |
|---|---|---|---|
| 20:17:08 | 11 | 101 | PASSED, try 1 |
| 20:17:49 | 15 | 105 | PASSED, try 1 |
| 20:18:25 | 14 | 104 | PASSED, try 1 |
| 20:19:03 | 16 | 105 | PASSED, try 1 |
| 20:19:40 | 16 | 105 | PASSED, try 1 |

Reading: no retries, no FAILED. Note that three of the five locked at poll 104–105, i.e. with
0–1 polls of margin under the OLD budget — exactly the edge the analysis predicted; any request
that arrives a few ms later (the 22-poll one captured at 19:23) needs poll 106+ and used to
fail. With 155 polls the margin is ~50 polls (~100 ms). Strictly, none of these five runs
*needed* the extra budget (all ≤ 105), so the proof of the fix's effect is the earlier failing
capture plus the arithmetic, not a >105 pass; a pass above 105 will show up in normal use and
is worth noting when seen. Standing state: override active; `--remove` reverts; a kernel
package update makes it moot (rebuild with the script if the wake regresses on the new kernel).
**Sent upstream 20:30:** `[PATCH] drm/amd/display: Allow 300 ms for HDMI FRL link training at
every rate` to amd-gfx (Cc Wentland, Li, Siqueira, Deucher, Zuo, dri-devel), Message-ID
`20260920013050.21259-1-djanice1980@gmail.com`. Tracking in `kernel-patches/SUBMITTING.md`.

## Sep 20 — CORRECTION: the overnight "No Signal" is NOT the FRL link-training timeout

David, after an overnight DPMS standby: *"the tv said no signal until changing refresh rate."*
He then ran `tools/hdmi-frl-lt-capture.sh` twice **while the TV was already dark** (11:50, 11:52;
logs `docs/logs/frl-lt-4k120-darkwake-*.log`). Neither DPMS cycle brought the picture back, and
both show a completely clean bring-up:

| step | 11:50 run | 11:52 run | good wake (Sep 19 20:17) |
|---|---|---|---|
| FRL rate written | 5 (10G x4) | 5 | 5 |
| link training | PASSED, try 1 (poll 99) | PASSED, try 1 | PASSED, try 1 |
| sink FRL_START in LTS:P | **1** (after 67 polls) | **1** (after 69 polls) | 1 |
| stream enable | HDMISTREAMCLK_EN=1, hpo_enc3_enable, unblank, no error | same | same |
| stream params | 3840x2160, 1188000 kHz, RGB 10-bpc, colorSpace 11, dsc 0 | same | same |
| **picture** | **none — TV says No Signal** | **none** | picture |

The driver-visible state is identical between a wake that produces a picture and one that does
not, down to the sink's own `FRL_START=1` acknowledgement, which is the sink saying "I am
locked, send video". So:

- **The C7-style LT fix does what it claims and no more.** With `max_polls = 155` the LT
  timeout is gone (7/7 first-try passes across two days). It does **not** fix this.
- **The failure is after LTS:P**, in the sink or the DP->HDMI PCON, and is invisible to the
  source. Both a 20 s DPMS cycle and (per Sep 10) an output disable/enable at the *same* mode
  fail to clear it; only a modeset to a **different timing** does (David used the refresh-rate
  switch; `kwinoutputconfig.json` rewritten 11:54:29, output now sitting at 3840x2160@60).
- Working hypothesis, unproven: after a long standby the PCON or the TV's receiver holds a
  stale state that survives an identical re-enable, and only a rate change (10G x4 -> TMDS or
  6G x4 and back) re-initialises it. Distinguishing PCON from TV needs data taken while dark.

Actions:
1. `tools/display-rescue` rewritten to **bounce the mode** (same resolution at its lowest
   refresh, 4 s, then back) instead of disabling/re-enabling at the same mode. This is exactly
   what worked by hand. `--hard` keeps the old disable/enable path.
2. `tools/hdmi-dark-diag.sh` added: run it **while dark, before rescuing** — connector status,
   EDID byte count (does the sink still answer DDC?), live CRTC bpc/colorspace, amdgpu
   connector/DP debugfs, recent kernel lines. Not yet run against a real dark screen.
3. The upstream patch's commit message claims the LT timeout is "the difference between
   reliable DPMS wakes at 4K60 and mostly dark ones at 4K120". Today's evidence contradicts
   that. A correction to the amd-gfx thread is drafted in `kernel-patches/SUBMITTING.md`.

### Sep 20 12:19 — caught it dark, with the source fully up; and the picture returned with no source action

`tools/hdmi-dark-diag.sh` run while the TV showed No Signal
(`docs/logs/hdmi-dark-20260920-121935.txt`). With the panel dark the source was **completely
up and scanning out**:

| probe | value while dark |
|---|---|
| connector `card1-HDMI-A-1` | status=connected, enabled, dpms=On, edid 256 B |
| live CRTC (crtc-1 = the LG) | `amdgpu_current_bpc` = 10, `amdgpu_current_colorspace` = **BT2020_RGB** |
| connector `output_bpc` | Maximum: 12 |
| FRL link training (11:50/11:52 captures) | PASSED first try; sink set FRL_START=1 |

So the GPU was driving 4K120 10-bit BT2020 RGB, the sink had acknowledged the FRL start, and
the TV still reported No Signal.

**Then the picture came back on its own.** Every display reconfiguration prints an HDR
infoframe burst even with `drm.debug=0`, so they can be timed exactly. Today's bursts:

    11:48:25  first bring-up after the overnight standby   -> dark
    11:50:35  capture 1 DPMS on                            -> dark
    11:52:22  capture 2 DPMS on                            -> dark
    11:53:42  mode -> 4K60                                 -> picture returned (delay unmeasured)
    12:19:16  mode -> 4K120                                -> dark at 12:19:35-40 (the diag above)
    (nothing after 12:19:16)                               -> picture appeared anyway

There is **no** amdgpu/drm activity in the journal between 12:19:41 and 12:25. The diag script
only reads sysfs/debugfs; opening the folio produced no reconfiguration. So the TV locked by
itself, more than ~25 s after the 12:19:16 modeset, with nothing further from the source.

**Consequences, and two claims of mine that the evidence has now retired:**
1. ~~The LT timeout causes the dark wake~~ — retired Sep 20 (LT passes, still dark).
2. ~~Only a modeset to a different timing recovers it~~ — retired by this capture: no action
   recovered it. What "worked" before was probably just elapsed time. Matches the earlier
   (Sep 7-10) observations *"it came up after about 2 minutes"* and *"screen just now came up"*.

**Where that leaves the diagnosis.** The source side is exonerated on every probe available.
The remaining candidates are the TV's own HDMI receiver and the DP->HDMI FRL PCON, taking tens
of seconds to minutes to lock **this particular signal** (4K120, 10 bpc, BT2020/HDR, 10G x4)
after a deep standby. Unproven. `tools/display-rescue` (mode bounce) is therefore **not** known
to help; it is kept because it forces a fresh attempt, not because it is demonstrated.

**The three experiments that would settle it** (each needs one overnight standby):
1. **Do nothing and time it.** Wake, touch nothing, and note when the picture appears. If it
   always appears within a couple of minutes, there is nothing to fix on the source and the
   answer is patience or a different signal.
2. **HDR off, 4K120.** If the picture is immediate, BT2020/HDR entry after deep standby is the
   trigger (the colorspace probe above makes this the leading suspect).
3. **4K60 overnight** as the control: known-good, 6G x4, no HDR change.

## Sep 20 — there is no DP-to-HDMI converter in this path (correcting a claim I repeated for weeks)

David asked me to look into "the DP to HDMI chip". There isn't one. Evidence from this machine:

- The LG link runs as **`SIGNAL_TYPE_HDMI_FRL`** — the DPMS logs print `signal=100`, and that is
  hex: `signal_types.h` has `SIGNAL_TYPE_HDMI_FRL = (1 << 8)` = 0x100 (and eDP's `signal=80` =
  0x80 = `SIGNAL_TYPE_EDP`, which confirms the hex reading). A converter-attached port would be
  `SIGNAL_TYPE_DISPLAY_PORT` (0x20).
- SCDC — the channel all the FRL link training runs over — is read and written with
  `link_query_ddc_data()`, i.e. straight over the HDMI DDC pins, not tunnelled through DPCD.
- The encoder is the APU's own HPO FRL link encoder (`hpo_frl_link_enc3_*`, `hpo_enc3_*`).
- The boot line **`[drm] DP-HDMI FRL PCON supported` is not a detection**. It is printed from
  `amdgpu_dm.c` whenever `dc->caps.dp_hdmi21_pcon_support` is set, and `dcn35_resource.c` sets
  that unconditionally for every DCN 3.5 ASIC. It says "this ASIC can drive a PCON", not "there
  is one attached".
- No HDMI bridge or retimer exists in the system: the only retimers the kernel knows about are
  the two Thunderbolt ones on the USB4 ports (`vendor=0x1da0 device=0x8833`).

So the only two parties on this link are the Strix Halo HDMI FRL transmitter and the LG C2.
Anywhere else in this repo that says "PCON" about the Z13's HDMI port is wrong; the statements
in `tools/` have been corrected, and `docs/dpms-wake-bug-report.md` now carries a correction
banner. **The patch already sent to amd-gfx also says "driven by a Strix Halo DP-HDMI FRL
PCON"** — that must be corrected whenever the follow-up goes out (noted in
`kernel-patches/SUBMITTING.md`).

## Sep 20 — someone else reports the same shape of failure on the same display engine

`External HDMI monitor fails to wake up from DPMS/consoleblank since kernel 6.18`, amd-gfx /
dri-devel, 2026-01-08 (https://ratatoskr.run/amd-gfx/2026/01/9269308/t):

- Strix **Radeon 880M / 890M** — same DCN 3.5 family as the 8060S here.
- External HDMI does not come back from DPMS or console blanking; the **internal panel resumes
  fine**; **nothing in dmesg**.
- The decisive detail: *"Users must wait several minutes in the off state before attempting
  wake — immediate wake attempts succeed, but delayed wake fails consistently."* That is
  exactly our pattern: 20 s capture cycles always recover, an overnight standby does not.
- Regression: 6.17 good, 6.18 bad. Alex Deucher asked for a GitLab ticket and a bisect. No fix,
  no workaround, and no sign the ticket was ever filed.

Notes on how it relates to us: their report predates FRL-by-default and never mentions
`dcfeaturemask`, so their link is probably plain TMDS — which would mean **the wake fault is not
FRL-specific**. And this machine already runs `amdgpu.dcdebugmask=0x800` (`DC_DISABLE_IPS`,
confirmed live: `/sys/module/amdgpu/parameters/dcdebugmask` = 2048), the Sep 7 fix for the
earlier IPS-exit variant, so whatever remains is *not* the IPS path. If their bug is IPS, 0x800
may fix theirs and not ours — i.e. possibly two faults with one symptom.

Also seen: Valve's SteamOS issue #2809 (LG OLED83C4 + FRL on kernel 7.2) — FRL gives 4K144
10 bpc HDR but loses VRR, fixed by using `dc_is_hdmi_signal()` in
`amdgpu_dm_update_freesync_caps()`. Unrelated to the wake fault, but it is the same
FRL-plus-LG-OLED combination in other hands, and it is the VRR answer for our earlier question.

**Added experiment (cheapest discriminator yet, TV side):** next time it is dark, *before*
touching the computer, use the TV remote to switch to another HDMI input and back. If the
picture returns immediately, the TV's receiver was stuck and the source is exonerated outright.

## Sep 20 — audit of every newer FRL/HDMI patch, i.e. "would a backport fix this?"

David asked this back when 7.4 was the topic and I answered about VRR instead. Proper answer,
from AMD's own `amd-staging-drm-next` (ahead of 7.4): **400 display commits since 2026-06-01**;
the ones touching FRL, HDMI, idle power or resume are listed below, with what each actually does.

| commit (date) | what it is | relevant to a sink that will not lock after standby? |
|---|---|---|
| Add DC link support for FRL / HDMI 2.1 DSC over FRL (06-03) | the original FRL series | already in 7.2.6 |
| dispatch compressed FRL cap check (07-25) | DML refactor | no |
| Silence link_dpms I2C retimer failures (07-27) | logging | no |
| Fix force FRL rate debug setting (07-24) | `<` → `<=` in `force_frl_rate` | no (debug knob) |
| Split DPMS ON into parts / Remove sink usage from DPMS / indenting (07-14..20) | refactor | no |
| Gate HDMI FRL status polling on active FRL link rate (08-04) | swaps the watchdog's gate from `connector_signal == HDMI_FRL` to `frl_link_rate != 0` | equivalent for us |
| switch max FFE level cap based on FRL link rate (08-04) | FFE levels 3 → 7 above 12G | no (we run 10G) |
| Cover crtc vblank IPS self-refresh restore (08-04) | KUnit | no |
| Decide zstate_support based off Z8 global support (08-09) | power states | IPS/Z path — **already disabled here** |
| Update and revert FRL LT Timeout behaviour (08-09) | 300 ms budget, **≥16 Gbps only** | no (this is what our own patch generalises) |
| restore FRL cap on non-destructive HDMI link verify (08-09) | stops a TMDS fallback across **hotplug** | no (we never fall back) |
| Cover / Refactor hdmi_frl_status_polling_work (08-21) | KUnit + move to `amdgpu_dm_connector.c` | no |
| HDMI 2.1 FreeSync / VRR (HF-VSDB) / ALLM (08-27) | gaming features | no (but this is the VRR answer) |
| Update HDMI link rate and DSC handling for DCN60 (08-28) | DCN 6.0 | no |
| **Exit IPS before connector detection on resume (09-04)** | IPS exit ordering on resume | **closest hit — but moot here**: this machine runs `dcdebugmask=0x800` (`DC_DISABLE_IPS`), all idle power states off, since Sep 7 |
| Shorten hdmi_frl_status_polling_workqueue (09-04) | fixes the `WQ_NAME_LEN` truncation we see in dmesg | cosmetic |
| Fix HDMI FRL audio enable (09-11) | audio | no |
| Use unsigned types for FRL cap check (09-11), Test * (09-11) | types, KUnit | no |

**Verdict: a backport is possible but there is nothing in it for this bug.** Nobody upstream is
working on "sink will not lock at FRL rates after a long standby", because as far as I can find
nobody has reported it — the closest report (Strix 880M/890M, Jan 2026, delayed wakes only) was
never ticketed or bisected.

### What your kernel already has, and the gap in it

7.2.6 runs a **200 ms FRL watchdog**: `hdmi_frl_status_polling_work()` in `amdgpu_dm.c` walks
every FRL link, calls `hdmi_frl_poll_status_flag()` (a raw SCDC read over DDC), and on
`FLT_UPDATE` runs `dc_link_detect(DETECT_REASON_RETRAIN)`. So the machinery to rescue a stuck
FRL link exists and is armed while the stream is committed.

During the dark minutes it never fired. The TV never asked for a retrain.

**The gap:** `hdmi_frl_poll_status_flag()` ignores the return value of `link_query_ddc_data()`.
If the sink's DDC were unreadable, the flags read back as zero and the watchdog silently does
nothing — *indistinguishable from "the sink is happy"*. So today we cannot tell "the TV is fine
and just slow" from "the TV is not answering at all". That is the next thing to instrument: a
print of the raw SCDC byte plus the DDC read result, built into the module override we already
run, then `tools/hdmi-frl-watch.sh` on the next dark morning.

## Sep 20 20:39 — the FRL watchdog is dead code in 7.2.x, and that IS the backport David asked for

The diagnostic from 0002 was installed (module override, boot 13:45) and
`tools/hdmi-frl-watch.sh` ran for five minutes from 20:39:22 with a live 4K120 10 bpc FRL stream
and `drm.debug=0x2`. Result: **not one `FRL WATCHDOG` line**. 3664 lines in the capture, every
one of them `amdgpu_dm_atomic_commit_tail` noise. The string is present in the running module,
so the print was compiled in and never executed.

Cause, in `hdmi_frl_status_polling_work()` (amdgpu_dm.c, 7.2.6):

    if (!dc_is_hdmi_signal(dc_link->connector_signal))
            continue;
    if (dc_link->connector_signal != SIGNAL_TYPE_HDMI_FRL)   /* never true */
            continue;

`link->connector_signal` is assigned once per link from the connector type in
`link_factory.c` — `SIGNAL_TYPE_HDMI_TYPE_A` for an HDMI connector — and **nothing in the tree
ever assigns `SIGNAL_TYPE_HDMI_FRL` to it**; only `stream->signal` takes that value (which is
why our DPMS logs show `signal=100`). So the second test always continues, the loop body is
never reached, and the 200 ms FRL watchdog has never polled a link on any 7.2 system. The work
item is queued and re-queues itself forever, doing nothing.

Upstream fixed this on 2026-08-04 — *"drm/amd/display: Gate HDMI FRL status polling on active
FRL link rate"* — by gating on `frl_link_settings.frl_link_rate == 0` instead. I had listed that
commit in the audit above as "equivalent for us". **That was wrong: it is the difference between
a working watchdog and dead code.** Backported here as
`kernel-patches/0003-drm-amd-display-Gate-HDMI-FRL-status-polling-on-active-rate.patch`,
built into the same module override (3 patches, clean build).

What this changes, and what it does not:
- It makes the sink-state diagnostic from 0002 actually emit, so the next dark morning finally
  answers whether the TV is talking and whether its lanes are locked.
- It restores the automatic recovery path: if the TV raises FLT_UPDATE while dark, the driver
  will now run `dc_link_detect(DETECT_REASON_RETRAIN)` within 200 ms. **That may fix the dark
  screen outright** — or reveal that the TV never asks, in which case it fixes nothing and the
  fault is wholly inside the TV. Unknown until a dark morning with this build.
- Timeline note for the earlier claim "nobody upstream is working on this": still true in the
  sense that nobody is chasing a slow-locking sink, but one upstream commit does bear directly
  on our symptom, and it was in the list I dismissed.

## Sep 20 22:51 — ROOT CAUSE, measured: the sink reports the link DOWN and nothing retrains

With 0003 installed the watchdog runs. `tools/hdmi-frl-watch.sh` caught a real dark screen
(after login, switching to 4K120, no external picture) and polled for five minutes:
**1443 consecutive polls, every single one identical** (log:
`docs/logs/frl-watch-4k120-darkwake-20260920-2251.log`):

    FRL WATCHDOG: rate=5 update0[ddc=1]=0x43 (FRL_START=0 FLT_UPDATE=0)
                  status[ddc=1]=0x40 (clk=0 ln0=0 ln1=0 ln2=0 ln3=0 flt_ready=1 dsc_fail=0)

Decoded:

| field | value | meaning |
|---|---|---|
| both DDC reads | ok | the sink is answering; it is not asleep or mute |
| `update0` 0x43 | STATUS_UPDATE, CED_UPDATE, RSED_UPDATE | **the sink is telling us its status changed** (and reporting character / RS error updates) |
| `FLT_UPDATE` | 0 | the sink is *not* using the one flag the driver reacts to |
| `status` 0x40 | FLT_READY=1 | the sink is **ready to be trained** |
| `CLOCK_DETECTED` | **0** | the sink sees **no clock** |
| all four lane locks | **0** | **no lane is locked** |
| source side | rate=5 active, CRTC scanning 10 bpc BT2020 | the source believes the link is up and is sending video |

So the link is genuinely **down** while the source believes it is up. The sink says so, in two
different ways, every 200 ms, for six minutes — and the driver ignores both, because
`hdmi_frl_poll_status_flag()` only returns "retrain me" on `FLT_UPDATE`. There is no reconfiguration
in the journal between 22:50:53 and the picture appearing around 22:57-22:58, so once again it
recovered without source action — the sink's receiver eventually latched on by itself.

That retires the "HDR/BT2020 entry" suspicion and the "TV is happy but slow" reading: the TV is
not happy, it is unlocked and asking for attention.

**Fix written and built: `kernel-patches/0004-...-retrain-FRL-link-on-sink-loss-of-lock.patch`.**
While an FRL rate is active and the sink reports no detected clock and no locked lane, the
watchdog now requests the retrain (`dc_link_detect(DETECT_REASON_RETRAIN)`), rate-limited to one
request every 5 s. Four patches now build clean into the module override.

This is simultaneously the candidate fix and the decisive experiment:
- if the next dark screen clears within a few seconds, the diagnosis is confirmed and the driver
  behaviour (retrain on loss of lock, not only on FLT_update) is the real bug — worth taking
  upstream with these logs;
- if retraining runs and the sink still reports no lock, the retrain itself is failing and the
  next question is whether the source PHY is actually transmitting (the `clk=0` hint), which
  needs the HPO FRL encoder state dumped;
- either way the log now says which.

Local-only caveat: the 5 s limiter is a file static (one FRL link assumed), so 0004 is not an
upstream candidate as written.

## Sep 21 — first overnight with the retrain patch: the monitor came up immediately

David: *"this morning the external monitor worked immediately. I did not get an opportunity to
run the script because of it."* The four-patch module was installed 2026-09-20 23:04 and the
machine booted 23:05, so this was its first overnight test.

**Not yet evidence.** The retrain request prints through `FRL_INFO` (drm_dbg), which is silent
unless `drm.debug=0x2` is set by hand, and it was not. The journal for this boot contains no FRL
lines at all. So we cannot tell whether:
- the watchdog saw loss of lock, retrained, and fixed it in under a second (the hoped-for case), or
- the sink simply locked on its own this time, as it has on plenty of mornings before.

One good overnight proves nothing either way — the fault has always been intermittent.

**Fixed by making the event self-recording:**
`kernel-patches/0005-...-log-FRL-loss-of-lock-at-warning-level.patch` promotes the request to
`DC_LOG_WARNING` and adds a matching line when the sink reports lock again, so an ordinary
journal (no debug flag, no watching) records the pair:

    HDMI FRL: sink reports loss of lock (status=0x40) with rate=5 active -- requesting retrain
    HDMI FRL: sink lock restored (status=0x5f)

At most one line per 5 s while unlocked, nothing at all on a healthy link. Five patches build
clean. From here the confirmation is passive: over the coming days,
`journalctl -b -k | grep "HDMI FRL"` (or `--since yesterday` across boots) answers three
questions at once — does the fault still occur, does the retrain fire when it does, and does the
lock come back within a poll or two of the request.

## Sep 21 — second dark morning, nothing logged, because 0005 was never installed

David: *"i logged in and it was not working. i opened the folio and before I could run the script
it came up. I ran the command anyway"* — and `journalctl -k --since yesterday | grep "HDMI FRL"`
returned only the boot capability line.

Cause: the running module was still the **four-patch** build installed 09-20 23:04 (boot 09-21
23:47). The warning-level logging (then 0005) was built but never installed, so the retrain code
*was* live during the dark screen and said nothing. Nothing is learnable from this morning.

Also fixed the underlying mess: the local patches had grown to four files, each rewriting lines an
earlier one added, which broke the build script's already-applied check twice (0004 after 0005,
then again). They are now **one** consolidated local patch, and the series is three files:

| patch | what | destination |
|---|---|---|
| 0001 | 300 ms LTS:3 budget at every FRL rate | upstream candidate (already sent; correction pending) |
| 0002 | gate the watchdog on the active FRL rate | backport of an upstream commit |
| 0003 | watchdog diagnostics, retrain on loss of lock, warning-level records | local only |

Verified: the three apply in order to pristine 7.2.6 sources, and the module builds clean from a
reset tree. `tools/amdgpu-frl-module/build.sh` header now warns against patches that edit each
other's lines.

### The build script now resets instead of guessing (Sep 21)

Three consecutive attempts to work out whether a patch was already applied in the source tree all
failed, and each failure stopped David from installing a module that was otherwise ready:
a reverse dry-run (broken by a later patch adding lines after an earlier one's hunk), then a
content marker taken from the patch's longest added line (broken first when a later patch rewrote
that line, then again on a patch touching two files, where the marker came from one file and the
filename from the other).

`tools/amdgpu-frl-module/build.sh` no longer guesses. It stamps `$SRC/.egpu-frl-patch-stamp` with
a hash of the patch set; if the stamp matches, the tree is already exactly right and nothing is
touched. If it does not match, every file the series touches is extracted fresh from the pristine
`cachyos-<ver>.tar.gz` next to the PKGBUILD and the whole series is applied from scratch.
Verified three ways: fully-patched tree without a stamp (reset and reapplied), stamp matching
(untouched), and a hand-corrupted file (reset and reapplied). All four log strings present in the
built module each time.

## Sep 22 00:05 — the retrain fires and restores lock in about a second (first live evidence)

First boot with the three-patch series loaded. `journalctl -k -b | grep -E "frl status polling|HDMI FRL"`:

    00:05:49  200ms frl status polling starts ...
    00:05:49  sink state changed -- status=0x5e (clk=0 lanes=1111 flt_ready=1) update0=0x43 rate=3
    00:06:00  sink state changed -- status=0x40 (clk=0 lanes=0000 flt_ready=1) rate=3
    00:06:00  sink reports loss of lock (status=0x40) with rate=3 active -- requesting retrain
    00:06:01  sink lock restored (status=0x5e)
    00:06:01  loss of lock -> requesting retrain      -> 00:06:02 lock restored
    00:06:21  loss of lock -> requesting retrain      -> 00:06:22 lock restored (rate=5)

Three loss/restore pairs, each restored in **0.3 - 1.3 s** of the request. The watchdog is armed,
the gate backport works, and the retrain does what it was written to do.

**Two things this log teaches about reading the status byte:**
- `CLOCK_DETECTED` is a TMDS-era bit and reads **0 on a healthy FRL link**. The healthy state
  here is `status=0x5e`: four lanes locked, FLT_READY, clock bit clear. The dark state is `0x40`:
  FLT_READY alone, **no lane locked**. So "clk=0" in the Sep 20 capture was not the smoking gun I
  read it as — the lane-lock bits were. The retrain condition requires both, so it is correct as
  written, but the Sep 20 note overstated the clock bit.
- `update0=0x43` is constant in both states (STATUS_UPDATE, CED_UPDATE, RSED_UPDATE), which is why
  the transition log masks it.

**Open question to watch, not yet a problem:** the three losses coincide with login-time mode
changes (greeter 4K60 = rate 3, then 4K120 = rate 5), so some of these are probably the normal
disable/enable transient rather than the fault, and the watchdog is retraining over the top of a
modeset in progress. It converged each time within about a second and the display came up at
4K120, which is exactly the case that has been failing. If spurious retrains become a nuisance —
or if a modeset ever gets stuck in a loop — the fix is a debounce: require the unlocked state to
persist two or three consecutive polls (400-600 ms) before requesting, which the real fault
(minutes long) would still trigger.

Status: waiting on days of ordinary use. Check any time with
`journalctl -k --since yesterday | grep -E "HDMI FRL|frl status polling"`.

