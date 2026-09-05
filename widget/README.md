# Blackwell eGPU Status — read-only Plasma 6 widget

A KDE Plasma 6 panel widget showing live status and telemetry for an NVIDIA Blackwell
eGPU attached over USB4/Thunderbolt: enclosure name and authorization state, driver
state, GPU utilization, power draw, VRAM, temperature, and PCIe RX/TX throughput.

## Credit

This is a stripped-down fork of the applet from
[**DamianKA1993/blackwell-egpu-manager**](https://github.com/DamianKA1993/blackwell-egpu-manager)
(MIT). All of the UI design, layout, and the original status/telemetry concept are
DamianKA1993's work — this fork only removes things. If you want the full manager
(mode switching, authorize/connect buttons, eGPU-only mode), use the original project.

## What was changed, and why

The upstream manager is a *controller*: its buttons load/unload driver modules, gate
PCI rescans through udev rules, and its "eGPU Only" mode removes the integrated GPU
from the PCI tree at runtime. On some machines those operations are exactly right. On
others — e.g. a Wayland session composited on the iGPU, where the eGPU is used purely
for PRIME offload/compute, or hardware where PCI remove/rescan on live devices wedges
the compositor — they are the most dangerous operations available, one misclick away.

This fork keeps the excellent status panel and deletes every side effect:

- **All action buttons removed** (Authorize / Connect eGPU / eGPU Only / Screen Manager).
  The widget can only observe.
- **No root anywhere.** Upstream installs a passwordless-sudo wrapper
  (`NOPASSWD: /usr/local/bin/blackwell-egpu`) so the applet can switch modes; with no
  actions there is nothing to elevate. No sudoers entry, nothing in `/usr/local`.
- **No udev rules.** Upstream ships rules that PCI-remove eGPU enclosure controllers on
  enumeration (gated by a `/tmp` flag file) so it can control driver bind timing. This
  fork does not touch how or when your eGPU attaches.
- **New self-contained status backend** (`blackwell-egpu-status`, installed to
  `~/.local/bin`). Strictly read-only: reads Thunderbolt sysfs for the enclosure, runs
  one `nvidia-smi` query (which doubles as a liveness probe) and one `nvidia-smi dmon`
  sample for PCIe throughput. If the card soft-dies, the widget visibly drops from
  "Hybrid Offload" back to "Standby" — a free health indicator.
- **"Speed" (PCIe link) field removed** — `LnkSta` on a Thunderbolt-tunneled device is
  virtualized by the TB controller and does not reflect real bandwidth. Showing it
  invites wrong conclusions; measure with `nvbandwidth` instead.
- Detection fixes picked up along the way: the iGPU can enumerate as PCI class
  "Display controller" rather than "VGA" (AMD Strix Halo does), and the Thunderbolt
  sysfs glob must skip retimer entries (`1-0:2.1`) or it grabs the wrong device.

## Requirements

- KDE Plasma 6 (Wayland or X11)
- `nvidia-smi` in PATH (any driver arrangement — works fine with manually built
  open-gpu-kernel-modules)
- Optional: `glxinfo` (mesa-utils) for a friendlier iGPU name

## Install

```sh
./install.sh
```

User-level only; the script prints how to add the widget to a panel (or run it as a
standalone window with `plasmawindowed`) and how to uninstall.

## Optional: clock-lock toggles (`clocklock/`)

One deliberate exception to "read-only": the widget can show two switches — **Clock
lock (hold P0)** and **Pin across reboots** — that apply/release
`nvidia-smi --lock-gpu-clocks` / `--lock-memory-clocks`. Holding the card in P0
suppresses P-state transitions, which on the reference system was a confirmed
kill trigger for GL context creation over the tunnel (survival went from ~25% to 8/8
with locks held — see the repo README). Credit where due: locking clocks for tunnel
stability is also what DamianKA1993's original manager does in its connect path — this
result independently corroborates that design choice on different hardware.

**Sep 5 note:** on the reference system the lock turned out to be compensating for a
silently misapplied `NVreg_DynamicPowerManagement` (distro file re-set it to `0x02`);
with `=0` truly in effect, unlocked launches stopped being fatal. The lock is now an
optional zero-Xid comfort rather than a requirement — see the repo README. The toggles
are still useful for exactly that.

The toggles appear only after you install the privileged helper:

```sh
sudo bash clocklock/install-clocklock.sh
```

Security design (deliberately unlike a blanket-NOPASSWD wrapper):

- The sudoers entry allows **only four literal commands** (`... on`, `... off`,
  `... pin`, `... unpin`) of a root-owned script — validated with `visudo -cf`
  before install.
- The helper reads no user-controlled paths; state flags live in `/run/blackwell-egpu`
  and `/etc/blackwell-egpu` (root-owned).
- "Pin" = a flag plus a oneshot systemd service that re-applies the lock at boot and
  whenever udev sees the nvidia driver bind a GPU (hotplug/replug) — it survives
  reboots, driver reloads, and recovery power-cycles.
- The widget cross-checks: if the lock flag is set but the card is not in P0 (lock
  lost to a reset), it shows a warning instead of a false "locked" state.

Trade-off: holding P0 costs ~20 W at idle (VRAM at full clock). Uninstall everything
with `sudo bash clocklock/uninstall-clocklock.sh`.

## License

MIT, same as upstream — see [LICENSE](LICENSE). Original applet copyright
DamianKA1993.
