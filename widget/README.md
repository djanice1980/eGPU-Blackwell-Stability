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

## Clock-lock toggles — removed (v1.5.0)

Versions 1.1–1.4 of this fork carried an optional pair of switches (lock the card in P0,
pin across reboots) behind a scoped root helper, because holding P0 was the only thing
that made GL launches over the tunnel survivable on the reference system. It turned out
the lock was compensating for `NVreg_DynamicPowerManagement` being **silently 2** (a
distro modprobe file sorted after the override). With `=0` genuinely in effect, unlocked
launches stopped being fatal — so the toggles, the helper, the sudoers entry, the
systemd unit and the udev rule are gone, and the widget is read-only again with **no
privileged component at all**. If you still want a manual lock for a zero-Xid session,
the two `nvidia-smi` commands are in the runbook; the widget's telemetry will show P0.
Credit stands: locking clocks for tunnel stability was DamianKA1993's design choice
first, and it worked for the right reason on his hardware.

## License

MIT, same as upstream — see [LICENSE](LICENSE). Original applet copyright
DamianKA1993.
