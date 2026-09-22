# Kernel patches (amdgpu)

Driver-side fixes found on this machine that are not (yet) upstream. Unlike `patches*/`
(NVIDIA open modules, applied by the pacman hook), these touch the in-tree amdgpu driver.

## 0001-drm-amd-display-Allow-300-ms-for-HDMI-FRL-link-training.patch (Sep 19, 2026)

One line in `drivers/gpu/drm/amd/display/dc/link/protocols/link_hdmi_frl.c`: the LTS:3
FLT_update budget goes from 105 polls (~210 ms) to 155 (~300 ms) at every FRL rate. Root cause
and the two captured trainings are in the runbook (Sep 19); the short form: the LG C2 needs
~180 ms after its LTP request to lock, and at 10G x4 (4K120 10-bit) its LTP request itself
comes ~45 ms after the rate write, so the total misses the single 210 ms budget that the driver
never restarts, while at 6G x4 (4K60) it just fits. AMD's own 7.4 change grants 300 ms only
for >= 16 Gbps.

- `*.patch` — for kernel 7.2.x (what CachyOS ships). Built and installed with
  `tools/amdgpu-frl-module/build.sh` as a module override, no custom kernel package.
  **Verified Sep 19 20:15**: 5/5 DPMS wakes at 4K120 10-bit RGB (10G x4) trained on the first
  try (logs in `docs/logs/frl-lt-4k120-fixed-*.log`), versus 1 in 2 failing before.
- `*.amd-staging-drm-next.patch` — the same change rebased on AMD's staging branch, which
  already carries the >= 16 Gbps conditional; this is the form to send to amd-gfx.

## 0002-drm-amd-display-Gate-HDMI-FRL-status-polling-on-active-rate.patch (Sep 20, backport)

Straight backport of upstream `drm/amd/display: Gate HDMI FRL status polling on active FRL link
rate` (amd-staging-drm-next, 2026-08-04), absent from 7.2.x. One line:

    -		if (dc_link->connector_signal != SIGNAL_TYPE_HDMI_FRL)
    +		if (dc_link->frl_link_settings.frl_link_rate == 0)

Without it the 200 ms FRL watchdog is dead code — `connector_signal` is `SIGNAL_TYPE_HDMI_TYPE_A`
for an HDMI connector and never `SIGNAL_TYPE_HDMI_FRL`, so every link is skipped. Proven on this
machine: five minutes of `drm.debug=0x2` with the diagnostics below installed and a live FRL
stream produced zero lines.

## 0003-local-HDMI-FRL-watchdog-diagnostics-and-retrain-on-loss-of-lock.patch (Sep 20-21, local)

Local only — the rate limiter and edge-detect state are file statics, fine for one FRL link. It
began as four separate patches; they were consolidated because each was rewriting lines the
previous one had added, which broke the build script's "is it already applied" check. Keep it as
one patch.

1. **Diagnostics, per 200 ms poll, `drm_dbg`** (silent unless `drm.debug=0x2`): the DDC result of
   each read, the Update_0 byte, and the status flags with clock-detect and per-lane lock bits.
   Upstream ignores the DDC return value, so a mute sink reads back as all-zero flags and looks
   identical to a happy one.
2. **Link re-enable on loss of lock.** While an FRL rate is active and the sink reports all four
   lanes unlocked, run `dc_link_dp_handle_link_loss()` — the DP hot-plug path's recovery, which
   is generic: dpms off then on over the link's pipes, re-running FRL link training. Debounced
   three polls (~600 ms) so modeset transients are ignored, one attempt per 5 s, capped at
   twelve. Upstream reacts only to `FLT_UPDATE`, which the sink raises during training, so a
   link that trains, is acknowledged with FRL_START, then loses lock is never noticed.
   `dc_link_detect(DETECT_REASON_RETRAIN)` was tried first and does **not** work: measured
   2026-09-22, twelve requests over 56 s caused no modeset and no lock.
3. **Warning-level record.** Lock-state transitions (masked to the lock-relevant bits, because the
   sink toggles its error-counter bits constantly), the retrain request, the recovery, and the
   `200ms frl status polling starts/stops` messages all land in an ordinary journal.

Confirmation is then passive:

    journalctl -k --since yesterday | grep -E "HDMI FRL|frl status polling"

| what the journal shows | reading |
|---|---|
| nothing but the boot `DP-HDMI FRL PCON supported` line | the fault did not occur, or the watchdog is not armed (check for the `polling starts` line) |
| `loss of lock ... requesting retrain` then `lock restored` | the fault occurred and the retrain fixed it — the confirmation being waited for |
| repeated `loss of lock` with no `lock restored` | the retrain runs and fails; next suspect is the source PHY not transmitting (`clk=0`) |
| `sink state changed` lines only | transitions happened without meeting the retrain condition; the sink was reporting lock while the panel was dark |

