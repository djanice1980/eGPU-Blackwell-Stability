# Draft: External HDMI display stays dark after DPMS wake on DCN 3.5.1 (Strix Halo) — no kernel error

Target: https://gitlab.freedesktop.org/drm/amd/-/issues (amdgpu / display)
Status: DRAFT — fill in the ladder results marked TODO before filing.

## Summary

External HDMI monitor does not come back after DPMS off → on. The internal eDP panel
resumes normally. The kernel logs **nothing** (no link-training failure, no error). A
full disable/enable of the output (fresh modeset) recovers it every time. The same
host + monitor + cable never exhibits this under Windows, and a different monitor/cable
on the same laptop fails the same way on Linux — so cable/monitor are exonerated.

Frequency correlates with link bandwidth: higher modes (4K120 10-bit HDR, which needs
FRL + DSC through this port's PCON) fail readily; lower modes are more robust. TODO:
exact first-surviving ladder step.

## Hardware / software

- ASUS ROG Flow Z13 GZ302EA, AMD Ryzen AI Max+ 395 (Strix Halo), Radeon 8060S iGPU
  (`0000:c4:00.0`, DCN **3.5.1**, `Display Core v3.2.384`, DMUB `0x09004E00`)
- HDMI port is behind a DP-to-HDMI FRL PCON (`[drm] DP-HDMI FRL PCON supported`)
- Kernel: 7.2.2-1-cachyos (also seen on 7.2.0). BIOS 314 (also on 311).
- Compositor: KDE Plasma 6.7.4, kwin_wayland
- Monitor: LG (EDID mfr GSM, product 49352). EDID (edid-decode): FRL max 6 Gbps × 4 lanes
  (24 Gbps), DSC 1.2a, 10/12-bit deep color, VRR 40–120 Hz
- Second, different monitor + cable (office) reproduces.
- `amdgpu.dcdebugmask` = 0 (defaults). Kernel cmdline otherwise unrelated
  (`pcie_aspm.policy=performance pcie_port_pm=off pci=realloc=off thunderbolt.clx=0`).

## Reproduction (deterministic, no need to wait for idle)

Output at 3840x2160@120, HDR on, WCG on, VRR off:

```
kscreen-doctor --dpms off      # displays blank
# press a key / move the mouse
```

Result: eDP-1 wakes; HDMI-A-1 stays dark ("No Signal" on the monitor).
`cat /sys/class/drm/card1-HDMI-A-1/{status,enabled,dpms}` → `connected enabled On`.
`dmesg`: no amdgpu/drm lines at all during the event. powerdevil's libddcutil display
redetection runs and does not recover it.

Recovery (works 100%):
```
kscreen-doctor output.HDMI-A-1.disable; sleep 2; kscreen-doctor output.HDMI-A-1.enable
```
→ kernel then emits a fresh modeset (`HDR SB:` infoframe lines) and the picture returns.

## Ladder (one variable at a time) — TODO fill in

| Step | Mode | HDR | Result |
|---|---|---|---|
| a | 3840x2160@120 | on | FAIL |
| b | 3840x2160@120 | off | TODO |
| c | 3840x2160@60 | off | TODO |
| d | 1920x1080@60 | off | TODO |

Observed trend: lower resolution/refresh = more stable.

## Control

Windows 11 on the identical hardware, monitor and cable: display always returns after
sleep/DPMS. Never observed in months.

## Related reports

- "External HDMI monitor fails to wake up from DPMS/consoleblank since kernel 6.18"
  (amd-gfx, Jan 2026; Radeon 880M/890M = DCN 3.5; eDP fine, external HDMI dark; 6.17
  OK). Same symptom on the same display-core generation. Bisect requested, none posted.
- 3471b9a31ce3 "drm/amd/display: Rework HDMI data channel reads" regression (LG C3 no
  signal after power-cycle) — fixed by "drm/amd/display: Improve HDMI info retrieval";
  that fix appears present in 7.2.2 (`skip_scdc_overwrite` path), so likely not this.
- "HDMI FRL and DSC Support for amdgpu" (amd-gfx, May 2026) — new in 7.2; the failing
  modes here are the FRL/DSC ones through a PCON.

## Diagnostics tried / planned

- `amdgpu.dcdebugmask=0x800` (DC_DISABLE_IPS): TODO
- `amdgpu.dcdebugmask=0x4` (DC_DISABLE_DSC): TODO
- `/sys/kernel/debug/dri/1/amdgpu_dm_ips_status` at failure time: TODO

Happy to bisect, test patches, or capture `drm.debug=0x1e` logs around the event.
