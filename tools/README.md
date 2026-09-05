# tools/

Small helpers that came out of the investigations in `docs/`. All user-level unless noted.

| Script | Purpose |
|---|---|
| `display-rescue` | Disable/re-enable every connected non-eDP output (forces a fresh modeset). Recovers an external display that stayed dark after DPMS wake. Bind it to a global shortcut — on Plasma 6 via KGlobalAccel DBus (`doRegister` + `setShortcut`) or System Settings → Shortcuts → Add Command. |
| `dpms-cycle.sh [N]` | Deterministic DPMS wake test: N blank/wake cycles with a y/n prompt per cycle, logged with kernel, `amdgpu.dcdebugmask`, mode and HDR state — the evidence format used in `docs/dpms-wake-bug-report.md`. |
| `greeter-display-diag.sh` | (sudo) Dumps the **plasmalogin** greeter's own KWin output config and its KWin log lines for this boot — for "external display dark until login" questions. |
| `greeter-hdmi-4k60.sh` | (sudo) Pins the greeter's entry for a specific monitor (edit the `edidIdentifier` prefix inside — it ships with the reference LG) to 3840x2160@60 / HDR off, with a backup. Use only if the greeter reliably fails to light a 4K120 FRL/DSC link at first modeset. |
| `99-usb4-tunnel-ports-awake.rules` | udev rule that pins the two AMD USB4 PCIe-tunnel root ports (`0000:00:01.1/.2` on the GZ302EA) to `power/control=on`, so tunnels can establish without waiting for something to wake a runtime-suspended port — a narrow replacement for the global `pcie_port_pm=off` flag. Also forces the NVIDIA eGPU (matched by vendor/class, any bus address) and its HDA function to `power/control=on`, overriding the shipped `71-nvidia.rules` that sets `auto` — see NVIDIA/open-gpu-kernel-modules#1228. Adjust the root-port addresses for other boards. |
| `manager-test/manager-test-prep.sh` | Snapshot-protected test harness for DamianKA1993/blackwell-egpu-manager on this host: creates a snapper snapshot published to the Limine menu, moves our DPM modprobe file and root-port udev pin aside (copies kept), prints the run order. `manager-test-restore.sh` reverses it. |
| `manager-test/manager-test-log.sh <label>` | Appends a fingerprint (manager state, 5786/NVIDIA PCI tree, USB4 links, root-port PM, nvidia params/clocks, relevant journal) to `~/egpu-manager-test-<date>.log`. |
| `manager-test/manager-mode3-retry.sh` | (sudo) The corrected Mode 3 attach: rescans, checks BAR0 via sysfs, and if unassigned removes the 5786 upstream port, waits 3/8/15 s for the GPU-port link, rescans the root port again; then finishes the manager's own modeset/persistence/clock-lock steps. Never runs `fuser -k`. |

The DPMS wake problem on the reference system (AMD DCN 3.5.1 iGPU, HDMI behind a
DP-HDMI FRL PCON) turned out to be the display core's **IPS** (idle power states) exit
path; the fix is the kernel parameter `amdgpu.dcdebugmask=0x800` (`DC_DISABLE_IPS`). See
the runbook's DPMS section and the bug-report draft in `docs/`.
