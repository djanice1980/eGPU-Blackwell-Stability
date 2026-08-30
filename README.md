# eGPU Blackwell Stability

Making an NVIDIA Blackwell eGPU (RTX 5070 Ti) actually usable on Linux over USB4 —
driver patches, a read-only Plasma 6 status widget, and the field notes behind them.

**Reference system** (everything here is verified on this hardware):

| | |
|---|---|
| Host | ASUS ROG Flow Z13 GZ302EA (AMD Strix Halo / Ryzen AI Max, integrated AMD USB4) |
| Enclosure | Razer Core X V2 (Intel JHL9480 "Barlow Ridge" TB5, `8086:5786`) |
| GPU | RTX 5070 Ti (GB203, `10de:2c05`) |
| OS / driver | CachyOS (Clang-built kernel), open-gpu-kernel-modules **610.57.04** + 6 patches |

**State of play:** eGPU auto-detected as external, clean attach, CUDA and Vulkan
compute/render-offload stable for hours at full power (~260 W sustained over the
tunnel). PRIME render offload works per-app while the desktop stays composited on the
iGPU. Driving the desktop *from* the eGPU, or hanging a monitor off it, does not work
on Blackwell over a tunnel — that failure is inside GSP firmware and no kernel-side
patch fixes it.

## [`patches/`](patches/)

Six patches against open-gpu-kernel-modules 610.57.04 that fix eGPU detection on
modern TB4/TB5/USB4 hosts and make GPU-loss handling survivable. Patches 01–05 are the
unmodified base set from [apnex/nvidia-driver-injector](https://github.com/apnex/nvidia-driver-injector)
— all design credit to apnex (see
[NVIDIA/open-gpu-kernel-modules#979](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979)).
Patch 06 is apnex's C5 crash-safety patch rebased for 610.57.04.

The [patches README](patches/README.md) covers what each patch does, apply order,
build instructions (including the Clang/LLVM flags CachyOS-style kernels require),
module options, and the platform flags that break AMD USB4 hosts (`pcie_aspm=off`,
`pcie_ports=native` — don't).

## [`widget/`](widget/)

**Blackwell eGPU Status** — a KDE Plasma 6 panel widget with live eGPU telemetry
(utilization, watts, VRAM, temperature, PCIe RX/TX) and enclosure/driver state.

It is a deliberately read-only fork of the applet from
[**DamianKA1993/blackwell-egpu-manager**](https://github.com/DamianKA1993/blackwell-egpu-manager),
whose author designed the UI and the original manager — thank you. This fork removes
all control actions (mode switching, PCI remove/rescan, udev gating, passwordless
sudo) for setups where the eGPU is a pure offload/compute device and those operations
are hazards rather than features. Install is entirely user-level: `widget/install.sh`.

## [`docs/`](docs/)

- [`egpu-runbook-v2.md`](docs/egpu-runbook-v2.md) — the full working-config runbook:
  what works and what doesn't (with evidence), kernel cmdline and why each flag is
  there, the rebuild-after-kernel-update procedure, recovery procedure after GPU loss
  (both sides must reset, in order), display-stack findings, and the failure taxonomy —
  the card is reliable as a *render* device and unreliable as a *display* device, and
  it's the phase of GPU work (state creation over the tunnel) that kills it, not the API.
- [`gz302ea-bios311-firmware-analysis.md`](docs/gz302ea-bios311-firmware-analysis.md) —
  PSP/UEFI decomposition of ASUS BIOS 311 vs. a current-AMD-PI Strix Halo BIOS: the
  SMU/MPIO components ASUS ships are multiple revisions behind, mapping cleanly onto
  the observed cold-boot USB4 tunnel failures and power-state hangs. Read-only
  intelligence for bug reports and BIOS-update requests.

## Clock-lock mitigation (preliminary result: working)

Locking GPU clocks (`nvidia-smi --lock-gpu-clocks` / `--lock-memory-clocks`) holds the
card in P0 and suppresses P-state transitions — one of the two confirmed kill triggers
(`KPerfBoost` perf-state changes during GL context creation over the tunnel). With
clocks locked, the GL-via-PRIME workload that previously killed the card on ~75% of
launches has survived **4/4 consecutive launches** (p≈0.004 by chance) with dmesg
completely silent — not even transient-retry lines, meaning the failure window is not
entered at all. Cost: ~20 W extra at idle (10.6 W → 30.6 W measured); load behaviour
unchanged. Details, exact commands, and caveats in the
[runbook](docs/egpu-runbook-v2.md).

## Licensing

- `patches/` — **GPL-2.0** (inherited from apnex/nvidia-driver-injector, matching the
  GPL leg of NVIDIA's dual MIT/GPL-2.0 open modules): [patches/LICENSE](patches/LICENSE)
- `widget/` — **MIT** (inherited from DamianKA1993/blackwell-egpu-manager):
  [widget/LICENSE](widget/LICENSE)
- `docs/` — CC-BY 4.0: reuse freely with attribution.

## Credits

- **[apnex](https://github.com/apnex)** — the entire patch investigation and base set;
  months of Blackwell eGPU forensics documented across
  [aorus-5090-egpu](https://github.com/apnex/aorus-5090-egpu) and
  [nvidia-driver-injector](https://github.com/apnex/nvidia-driver-injector).
- **[DamianKA1993](https://github.com/DamianKA1993)** — the Plasma applet this repo's
  widget is forked from.
- hvico/Razer-Core-v2-Linux-Fix and cpburnz's Strix Halo notes for prior art on this
  exact hardware combination.
