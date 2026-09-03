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

| Component | ASUS 311 | **ASUS 314** | MF 1.09 (current PI) | Notes |
|---|---|---|---|---|
| SMU firmware (MP1, `SMU_OFFCHIP_FW`) | **A.64.2.0** | **A.64.7.0** | **A.64.9.0** | 311 was 7 behind; 314 is 2 behind (+5) |
| MPIO firmware (`MPIO_FW~0x5d`) | **0.10.2.FA** | **0.10.4.76** | **0.10.6.91** | 311 was 4 behind; 314 is 2 behind (+2) |
| ABL0 (AGESA bootloader) | 53.12.10.12 | **53.12.10.15** | 53.12.10.15 | 314 fully caught up |
| USB4 controller/PHY fw (`USB4~0xa6`) | 3.91.47.47 | 3.91.47.47 | 3.91.47.47 | **identical across all three** |
| USB_TYPEC_DP | 3.77.72.93 | 3.77.72.93 | 3.77.72.93 | identical |
| USB_SS_FW | 3.73.94.20 | 3.73.94.20 | 3.73.94.20 | identical |
| SMU_OFF_CHIP_FW_2 / MP5_FW | (not recorded) | A.64.7.0 | — | move with SMU |

(psptool `sha384_inconsistent` flags on MPIO/ABL entries appear on all images equally —
tool-side parsing noise for these entry types, not tampering.)

## BIOS 314 update (Jul 26 2026 build; analyzed Sep 2 2026)

ASUS 314 (`GZ302EA.314`, 32 MiB + 2 KiB ASUS header, same capsule shape as 311) advances
exactly the components this analysis fingered, toward the known-good reference:

- **SMU A.64.2.0 → A.64.7.0** (+5 revisions) — the power-state-transition processor;
  the s2idle-no-resume suspect. Biggest single move in the image.
- **MPIO 0.10.2.FA → 0.10.4.76** (+2) — IO-die lane/PHY bring-up incl. the USB4 host
  routers; the primary cold-boot-tunnel-establishment suspect.
- **ABL0 → 53.12.10.15** — now matches current PI.
- USB4 PHY / TYPEC / SS firmware unchanged — they were already identical to the working
  reference, consistent with "link quality is fine, establishment is what fails."

So 314 is directly on-target for the two remaining hardware open items (cold-boot USB4
lottery, s2idle resume). Same caveat as below still holds: version movement toward the
reference is not proof these deltas fix these bugs — AMD PI changelogs are NDA'd.

**Pending: flash + retest.** The clean same-board before/after this doc always wanted.
After flashing, measure (1) cold-boot tunnel success rate with enclosure attached (was
~70% failure on 311, though re-baseline on kernel 7.2.2 first — see runbook), and
(2) whether s2idle now resumes. The S5-poweroff hang is NOT a valid 314 test — it was
already fixed by kernel 7.2.2, not firmware (see runbook retraction).

Capsule SHA-256 (extracted from `ASUS_GZ302EA_314_BIOS_Update.exe`):
`accf8cad56b556b007689b82b426d27a1e36fc9722508a84a86d99f1c0d22ba7`

## Cross-vendor PI intelligence (Sep 2 2026)

AMD PI (the "StrixHaloPI-FP11" blob carrying SMU/MPIO/AGESA) is shared across all Strix
Halo vendors, so other OEMs' public changelogs are a proxy for what AMD changed at a given
PI level — AMD's own notes are NDA'd. Landscape as of this date:

| Vendor BIOS | AMD PI | Relevance |
|---|---|---|
| Framework Desktop 3.04 | 1.0.0.2 | baseline PI 1.0.0.2 |
| Framework Desktop 3.06 | 1.0.0.2c | newest public PI seen |
| Minisforum SHWSA 1.09 | 1.0.0.2b patchC | the "current PI" reference used above |
| ASUS GZ302EA 314 | ~1.0.0.2/2a-class (inferred from SMU A.64.7 / MPIO 0.10.4) | still behind Framework/MF |

**Key cross-vendor finding — USB4 tunneling is PI-sensitive in BOTH directions.**
Framework users reported that the 3.04→3.05 BIOS jump (a PI bump) *broke* USB4 PCIe
tunneling: a TB/USB4 NVMe enclosure fell back to a SCSI/USB3.2 path (40→10 Gbps), i.e.
PCIe tunneling stopped establishing. This is direct evidence that AMD PI revisions move
USB4/Thunderbolt tunnel behavior on this exact silicon — the same subsystem as the
GZ302EA cold-boot lottery — and that a PI change can regress it, not only fix it.

**Practical consequence for flashing 314:** do not assume it can only help the cold-boot
tunnel. Treat cold-boot success rate as a metric to re-measure after flashing, in both
directions, and keep the 311 findings on record in case 314 regresses tunneling the way
Framework's 3.05 did for some hardware. (The SMU/s2idle side has less regression
precedent and a bigger version jump, so it's the more likely net win.)

Sources: Framework knowledgebase + community BIOS 3.03–3.06 threads and the
"USB4 / Thunderbolt issues on Framework Desktop" thread (frame.work), Sep 2026.

## Flashing the GZ302EA BIOS from Linux (VERIFIED Sep 3 2026, 311 → 314)

The firmware is **AMI Aptio** (DMI vendor "American Megatrends International", release
5.36) — Insyde tools (H2OFFT) do not apply. ASUS distributes the BIOS as a **UEFI capsule**
inside a Windows wrapper; the same capsule works through Linux's standard capsule path.

**Extract the capsule** (the `.exe` is a 7z-in-PE self-extractor):
```sh
7z x ASUS_GZ302EA_314_BIOS_Update.exe -o x1      # yields x1/Cabfile/GZ302EA.314
```
`GZ302EA.314` = 32 MiB image + 2 KiB ASUS header, outer capsule GUID
`4a3ca68b-7723-48fb-803d-578cc1fec44d` ("AMI Aptio extended EFI capsule"). The bundled
`.inf` targets firmware GUID `0640b5c2-f018-5a2f-b136-cb52b2e83238` — identical to the
ESRT "System Firmware" device fwupd exposes. ASUS's own page notes the update is also
delivered via Windows Update, i.e. UpdateCapsule — the interface fwupd uses.

**Route A — fwupd capsule-on-disk (verified working):**
1. Quirk so fwupd passes the raw AMI capsule instead of re-wrapping it under the ESRT
   GUID — `/etc/fwupd/quirks.d/asus-gz302ea.quirk`:
   ```
   [0640b5c2-f018-5a2f-b136-cb52b2e83238]
   Flags = no-capsule-header-fixup
   ```
2. On AC power: `sudo fwupdtool install-blob GZ302EA.314 <device-id>` where the device
   id comes from `fwupdtool get-devices` (the entry carrying that GUID). fwupd writes the
   capsule to the ESP (`EFI/UpdateCapsule`) and sets OsIndications; nothing is flashed yet.
3. Reboot. Firmware verifies the ASUS/AMI signature and applies the update (logo +
   progress bar, ~1–2 min, may reboot twice).
4. Verify: `cat /sys/class/dmi/id/bios_version` → `GZ302EA.314`; `fwupdmgr get-devices`
   System Firmware version 788 (= 0x314; 311 showed as 785).

Preconditions observed on the reference system: fwupd 2.1.7 with `uefi_capsule` plugin
Ready; ESP = 4 GB vfat at `/boot`; Secure Boot off; efivarfs rw. Failure mode of this
route is benign (a rejected capsule is simply not applied and fwupd reports an error).

**Route B — ASUS EZ Flash 3 (in-BIOS):** copy `GZ302EA.314` to the ESP or a FAT32 USB
stick; F2 → Advanced → ASUS EZ Flash 3 Utility → select the file. Vendor-sanctioned;
use it if Route A ever fails. ASUS also publishes a separate "BIOS for ASUS EZ Flash
Utility" zip on the ROG support page.

Either route: **BIOS settings reset to defaults** afterwards. Kernel cmdline (limine)
and manually built kernel modules are on disk and unaffected.

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
