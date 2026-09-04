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
the margin. **But the decisive control is Windows on the same host + same monitor + same
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
**Step 1 result (Sep 4): PASS.** With `amdgpu.dcdebugmask=0x800` on the cmdline
(`dcdebugmask=2048`; `amdgpu_dm_ips_status` shows `IPS config: 1` = DMUB_IPS_DISABLE_ALL
and all IPS entry/exit counts 0), the deterministic repro at 4K120 + HDR **survived** —
the first time it ever has at that mode. n=1 so far; repeat several cycles before calling
it. If it holds: DCN 3.5 IPS exit is the mechanism, `0x800` is the standing workaround
(cost: the display core never enters its idle power states — a few hundred mW to ~1 W of
idle power on the iGPU, no functional loss), and the upstream report gets its key line.
Side note seen on the same boot: the external display stayed dark on the plasmalogin
greeter and only lit after login — being investigated separately (greeter output config),
not obviously related to IPS.

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
pcie_port_pm=off
pci=realloc=off
```
(Current as of Sep 3 2026 — `pcie_ports=native` removed Aug 26, `thunderbolt.host_reset=0`
removed Sep 3; see the bullets for why.)

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
