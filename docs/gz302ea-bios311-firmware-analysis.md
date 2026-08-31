# GZ302EA BIOS 311 — Platform Firmware Currency Analysis

**Date:** Aug 26, 2026
**Method:** UEFIExtract NE A75 structural decomposition + PSPTool directory analysis of two
retail Strix Halo BIOS images. No modification attempted or possible (PSP signature
enforcement); this is read-only intelligence.

**Images compared:**
- ASUS ROG Flow Z13 **GZ302EA BIOS 311** (Aug 2025, latest available as of this analysis;
  32 MiB capsule, 2 KiB ASUS header)
- Minisforum **SHWSA (MS-S1 series) BIOS 1.09** (Jun 8 2026, carries AMD **StrixHalo PI
  1.0.0.2b patchC** per its release notes; 32 MiB raw)

Both are AMD Strix Halo (Ryzen AI Max) platforms. Minisforum additionally carries
`AmdCpmDiscreteUSB4{Pei,Dxe,Smm}` for its discrete Barlow Ridge TB5 host — not present on
GZ302EA, which uses only the integrated AMD USB4 host routers (`AmdUsb4Pei`/`AmdUsb4Dxe`).
The comparison below covers only the shared, integrated-USB4-relevant components.

## PSP firmware directory comparison

| Component | ASUS 311 | MF 1.09 (current PI) | Notes |
|---|---|---|---|
| SMU firmware (MP1, `SMU_OFFCHIP_FW`) | **A.64.2.0** | **A.64.9.0** | 7 revisions behind |
| MPIO firmware (`MPIO_FW~0x5d`) | **0.10.2.FA** | **0.10.6.91** | 4 revisions behind |
| ABL0 (AGESA bootloader) | 53.12.10.12 | 53.12.10.15 | behind |
| USB4 controller/PHY fw (`USB4~0xa6`) | 3.91.47.47 | 3.91.47.47 | **identical** |
| USB_TYPEC_DP | 3.77.72.93 | 3.77.72.93 | identical |
| USB_SS_FW | 3.73.94.20 | 3.73.94.20 | identical |
| `AmdUsb4Dxe` (AGESA UEFI module) | 132,096 B, md5 22c8137f… | 132,736 B, md5 94baadbc… | different (newer) build |

(psptool `sha384_inconsistent` flags on MPIO/ABL entries appear on both images equally —
tool-side parsing noise for these entry types, not tampering.)

## Mapping to observed GZ302EA-on-Linux failures

1. **Cold-boot USB4 tunnel never establishes** (~70% of cold boots; hotplug always works;
   software NHI unbind/rebind does NOT recover it — failure is below driver probe).
   **MPIO firmware owns IO-die lane/PHY bring-up including the USB4 host routers.** ASUS
   ships 0.10.2; four revisions of MPIO fixes exist. The unchanged USB4 PHY firmware
   plus changed MPIO firmware matches the symptom: link quality is fine once up; link
   *establishment/bring-up at boot* is what fails.
2. **s2idle never resumes; ~~S5 poweroff hangs~~** — **RETRACTED for S5 (Aug 30):** the
   S5 poweroff hang was fixed by a Linux kernel update (broken on 7.2.0, fixed by
   7.2.2-1-cachyos) with no BIOS change, so it was kernel-side despite sysrq 'o' also
   failing — it is no longer evidence for the SMU-firmware mapping. The s2idle
   no-resume claim stands but needs a retest on ≥7.2.2 before being cited. The SMU
   version delta itself (A.64.2 vs A.64.9) remains a fact; only this symptom
   attribution is withdrawn.
3. **Vendor-fixable Linux TB bugs are precedented on this platform:** Minisforum 1.05
   changelog: *"Fixup TBT5 device can't use if plug after enter Ubuntu"* — a
   Linux-specific tunnel bug fixed in BIOS, plus firmware-side ASPM disable for TBT5.

## What this supports

- **To ASUS:** GZ302EA BIOS 311 ships SMU/MPIO/AGESA-USB4 components that AMD has since
  revised multiple times (PI 1.0.0.2b patchC era). A BIOS refresh carrying current PI is
  the ask; the version deltas above are the evidence it's overdue. The product is
  marketed for eGPU use.
- **To kernel/AMD (drm/amd work item 5208, delayed-rescan thread):** affected-machine
  fingerprint — GZ302EA + BIOS 311 = MPIO 0.10.2.FA / SMU A.64.2.0. If the cold-boot
  enumeration failure correlates with pre-0.10.6 MPIO, that's quirk-key material and
  narrows AMD's search. Windows-vs-Linux behavior difference remains explained by the
  Windows USB4 CM handling boot-present topology differently, but stale MPIO may set up
  the marginal state the Linux CM fails on.

## Caveats

- Version deltas prove ASUS is behind, not that the specific deltas fix these specific
  bugs — AMD PI changelogs are NDA'd; the correlation is subsystem-level (right components,
  right symptoms), not commit-level.
- Cross-vendor comparison: board-specific configuration differs; only AMD-common component
  versions were compared, but a same-board before/after (ASUS 311 → future 312) remains
  the clean experiment.
- Nothing here is flashable or transplantable — PSP signature verification makes
  modification a brick. Intelligence only.

## Reproduction

```
UEFIExtract <image> report        # structure + module inventory
UEFIExtract <image>               # full dump; diff AmdUsb4Dxe PE32 bodies
psptool <image>                   # PSP directory with per-entry versions
# ASUS capsule: strip leading 2048 bytes to get the raw 32MiB flash image
```
