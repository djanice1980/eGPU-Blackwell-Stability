# blackwell-egpu-manager v1.5.5 on AMD Strix Halo — test notes (2026-09-05)

Host: ASUS ROG Flow Z13 GZ302EA (Ryzen AI Max+ 395, Strix Halo, native USB4 host routers
1022:158d/158e, tunnel root ports 00:01.1/00:01.2). Enclosure: Razer Core X V2 = Intel
JHL9480 Barlow Ridge hub, 8086:5786 (upstream 61:00.0, GPU on downstream 62:00.0, three
empty downstream ports 62:01-03). GPU: RTX 5070 Ti (10de:2c05). CachyOS, kernel 7.2.3,
open modules 610.57.04 (apnex-patched), BIOS 314. KDE Plasma 6 Wayland.

Deviations from "out of the box" (disclosed): apnex patches in the driver; kernel cmdline
pcie_aspm.policy=performance thunderbolt.clx=0 pci=realloc=off amdgpu.dcdebugmask=0x800.
Our DPM=0 modprobe file and our root-port udev pin were moved aside for the test, so the
driver default DynamicPowerManagement=2 applied. Snapper snapshot taken first.

## Timeline (all times local, journal-verified)

- 15:33:48  kernel enumerates the enclosure at cold boot, BARs assigned by firmware windows.
- 15:33:50  udev coldplug replays "add" -> Damian's rule PCI-removes the 5786 tree. nvidia
            not loaded yet. Matches his design.
- 15:33:52  nvidia autoloads (kms hook / modalias), no device.
- 15:34:18  USB4 tunnel rebuilt after the thunderbolt host reset -> pciehp Link Up ->
            full tree enumerated WITH the GPU, BAR0 ac000000, BAR1 5800000000.
- 15:34:19  nvidia probes and fully initializes (GSP up, nvidia-drm initialized, HDA).
- 15:34:20  udev rule fires on the bridge add ~2 s late -> whole tree removed while the
            driver is bound. Teardown orderly (gpuLost=false), 0 Xid. End state = Mode 2.
  => On this host the rule is a post-hoc detach, not a pre-attach block: nothing stops
     modalias autoload, so the driver races the rule and wins.

- 15:37:11  `blackwell-egpu set 3`. Its `fuser -k /dev/nvidia*` SIGKILLed kwin_wayland
            (KWin holds /dev/nvidiactl whenever the module is loaded, GPU or not). Plasma 6
            respawned KWin (new PID 10488), plasmashell + 3 services restarted; every
            Wayland client that could not reconnect died. His `modprobe nvidia
            NVreg_DynamicPowerManagement=0x00` was a no-op: udev autoload had already loaded
            the module with the distro default during the rescan -> params show DPM=2.
- 15:37:12  His root-port rescan: switch scanned while the GPU port link (62:00.0, no
            HotPlug capability) was not yet trained -> kernel sized the switch windows for
            3 empty ports (6 MB) -> GPU appeared a moment later needing ~640 MB -> every
            BAR "can't assign; no space" -> NVRM "BAR0 is 0M @ 0x0", probe failed (-1).
            Two-phase enumeration, not a driver bug and not his setpci work.

- 15:44:16  remove 61:00.0 + rescan root port after 1 s: switch back, GPU port empty
            (link not yet up; port has no pciehp so nothing follows up).
- 15:49:05  rescan of 62:00.0 alone finds the GPU immediately (link trained at rest) but
            windows are already fixed at 6 MB -> same BAR0=0M.
- 15:51:00  v3 retry: GPU port LnkSta DLActive=1 Gen4 x4 before removal.
            pass 1: remove 61:00.0, wait 3 s, rescan root -> GPU not found; port rescan at
            +2 s finds it (so link retrains ~3-5 s after the upstream port is re-added).
            pass 2: remove 61:00.0, wait 8 s, rescan root -> GPU present at scan time ->
            BAR0 ac000000 (64M), BAR1 5800000000 (256M) assigned, nvidia probes, "external
            GPU detected", P0, Gen4 x4, clocks locked 2000-max / 14001 (his lock).
  => Under pci=realloc=off a full pass with the GPU present sizes correctly. realloc is
     NOT the blocker; timing is.

## Findings for Damian (actionable)

1. fuser -k /dev/nvidia* kills the Wayland compositor on KDE when nvidia is loaded.
   Needs a guard: never kill kwin_wayland/plasmashell; refuse instead, or only kill PIDs
   from `nvidia-smi pmon` like set6 already does.
2. Module parameter race: udev modalias autoload loads nvidia during the rescan before
   his explicit modprobe. Fix: `modprobe nvidia NVreg_DynamicPowerManagement=0x00` BEFORE
   the rescan (module loads fine with no device), or ship a modprobe.d file.
3. Rescan timing on non-hotplug GPU ports: after the root-port rescan, check BAR0 via
   /sys/bus/pci/devices/<gpu>/resource; if 0, remove the 5786 upstream port, poll the GPU
   port LnkSta (setpci CAP_EXP+12.w bit 13) or wait ~8 s, rescan the root port again.
   Verified working on this host.
4. Cosmetic: when nvidia-smi fails, its NVML error goes to stdout and lands in the
   egpu2/gpu_util JSON fields (invalid JSON for the applet).
5. Boot race: the udev rule cannot prevent driver attach on distros that autoload nvidia;
   on this host it detached a fully initialized GPU 2 s after probe (clean here, 0 Xid).

## Still to run
- 30 min game at the state his Mode 3 produced here (clocks locked, DPM=2), log after-game.
- Mode 6 safe detach (close Claude desktop first; Meta+Shift+D ready).
- Cold-boot repeats.

## Load result
- 15:56-16:45 Steam game session (~50 min) at the state his Mode 3 produced here (clocks locked 2000-max/14001, DPM=2): 0 Xid, no NVRM/AER/link events; GPU P0 at lock floor 1987 MHz, 48 C, 30 W idle afterwards.

## Mode 6 (safe detach) result, 16:47:02
- Ran from Mode 3 with no active GPU contexts (Steam closed). nvidia-drm removed the device cleanly (gpuLost=false), 63:00.0 PCI-removed, eGPU DRM nodes gone, 0 Xid. kwin_wayland (10488), plasmashell and Xwayland all kept their PIDs: display survived. Applet back to Mode 2.
- Leftover: the GPU HDA function 63:00.1 is NOT removed and stays bound to snd_hda_intel (his set6 removes only the VGA function). Likely related to his KNOWN_ISSUES #2 audio disappearance. Suggest removing 63:00.1 first, then 63:00.0.
- nvidia/nvidia_modeset stay loaded (by design). Our patched teardown path ran here, so stock-driver behaviour on this exact removal is not proven by this test.

## Cold boot 2 (16:49:38)
- Same sequence as boot 1: firmware enumeration -> udev coldplug removal -> tunnel rebuilt 16:50:08 -> nvidia bound and initialized 16:50:09 -> udev rule detached the tree (gpuLost=false), 0 Xid, Mode 2. Attach via retry: root-port rescan alone found no GPU (his Mode 3 would fail again), 8 s full pass attached cleanly, Gen4 x4, locked clocks.

## Cold boot 3 (16:52:45)
- Boot sequence identical (bind 16:53:16, udev detach, 0 Xid, Mode 2). Attach differed: the retry ran 22 s after the detach and the FIRST root-port rescan found the GPU with BARs assigned (no remove/wait needed). Boot 2 ran 37 s after its detach and needed the 8 s pass; boot 1 (his set3, ~3 min after) got the two-phase BAR0=0M failure.
  => GPU visibility at rescan time is timing-dependent: 1 of 3 immediate rescans succeeded. The BAR0 check + remove/wait/rescan loop converged 3/3. Hypothesis: the GPU-port link drops some time after the switch is removed (ports left in D3/L1), and retrains 3-5 s after re-enable; a rescan soon after the detach still sees the trained link.

## Totals
- Cold boots with enclosure attached: 3/3 reached Mode 2 with a clean driver detach (0 Xid each boot). His Mode 3 as shipped: 0/1 (BAR0=0M) plus the compositor kill. Attach via corrected sequence: 3/3. Load: ~50 min, 0 Xid. Mode 6: 1/1 clean, HDA function orphaned.

## Uninstall (16:58)
- uninstall.sh removed the backend, the udev rule (answered Y) and the applet, but NOT /etc/sudoers.d/blackwell-egpu: its `[ -f ... ]` check runs unprivileged and /etc/sudoers.d is mode 750, so the test is false and the NOPASSWD line stays. Removed by hand afterwards. Finding 6 for Damian: use `sudo test -f`.
