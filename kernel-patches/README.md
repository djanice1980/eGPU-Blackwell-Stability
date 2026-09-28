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
   three polls (~600 ms) so modeset transients are ignored, then one attempt every 5 s for
   twelve attempts, then once a minute with no hard stop (Sep 25). A polling gap over 2 s
   (output switched off) resets the episode. Upstream reacts only to `FLT_UPDATE`, which the sink raises during training, so a
   link that trains, is acknowledged with FRL_START, then loses lock is never noticed.
   `dc_link_detect(DETECT_REASON_RETRAIN)` was tried first and does **not** work: measured
   2026-09-22, twelve requests over 56 s caused no modeset and no lock.
3. **Warning-level record.** Lock-state transitions (masked to the lock-relevant bits, because the
   sink toggles its error-counter bits constantly), the retrain request, the recovery, and the
   `200ms frl status polling starts/stops` messages all land in an ordinary journal.
4. **Sink error counters (Sep 27).** While every lane is unlocked, and once at lock, read SCDC
   0x50-0x5A (per-lane error counts + Reed-Solomon corrections, each with a valid flag) and log
   them with the time since the episode began — at the first unlocked poll, on any change (at
   most 1/s), and at lock. Looking for a readiness signal to replace the fixed retry timer. There
   is none: the valid flags stay clear until lock.
5. **`mutex_trylock`, never `mutex_lock` (Sep 27).** `amdgpu_dm_atomic_commit_tail()` holds
   `dc_lock` while it calls `cancel_delayed_work_sync()` on this work; a blocking lock here froze
   the desktop at 20:33 on Sep 27. A commit holding the lock is changing the display anyway, so
   the pass is skipped (logged) and the retry schedule tries again.
6. **No lock-free action on the sink's update flags (Sep 27).** Upstream's poll cleared
   `FRL_START`/`FLT_UPDATE`/`SOURCE_TEST_UPDATE` in the sink and reprogrammed the transmitter, even
   re-running link training, with no lock held. That races a commit's own training, which polls
   the same flags every 2 ms. Now the flags are only logged (raised, cleared, how long). A
   `FLT_UPDATE` still up on two consecutive polls requests the same locked full re-enable as
   point 2: every 5 s for three requests, then once a minute. Every re-enable is logged with its
   reason.
7. **Settle window after link training (Sep 28).** The debounce used to count polls taken during
   a commit's own link training, when the TV is unlocked by definition. At a 4K60 -> 4K120 switch
   that made the watchdog tear down the fresh link 21-117 ms after FRL_START, but the TV needs
   0.42-0.83 s after FRL_START to lock. Every training start and the end of the FRL_START
   handshake now stamp a timestamp, and unlocked polls within 4.4 s of it are not counted, so
   the first re-enable comes ~5 s after training, the same time every retry link gets. (It was
   2 s at first, and was lengthened after locks up to 2.7 s were measured.) When the TV locks,
   the watchdog logs `sink locked N ms after the last link training`.

Confirmation is then passive. `journalctl -k` covers **only the current boot**, even with
`--since`, so this form reads every boot in range:

    journalctl _TRANSPORT=kernel --since yesterday | grep -E "HDMI FRL|frl status polling|DMCUB error|power_psr"

| what the journal shows | reading |
|---|---|
| nothing but the boot `DP-HDMI FRL PCON supported` line | the fault did not occur, or the watchdog is not armed (check for the `polling starts` line) |
| `loss of lock ... re-enabling the link` then `lock restored` | the fault occurred and the re-enable fixed it |
| `continuing once a minute` then more `loss of lock` lines | the sink is not locking even after a minute of fast retries; the loop keeps going at one attempt a minute |
| `display commit in progress -- link re-enable skipped this pass` | a request collided with a commit and stepped aside (point 5); the next attempt follows |
| `sink raised FLT_UPDATE` / `FRL_START` / `SOURCE_TEST_UPDATE`, then `cleared after N ms` | the watchdog saw a sink flag (point 6); before Sep 27 it would have acted on it lock-free |
| `FLT_UPDATE still raised after 2 polls ... re-enabling the link` | the sink asked for a retrain that nothing was running; handled through the locked path |
| `sink locked N ms after the last link training` | lock latency after training (point 7); values near or above 4400 mean the settle window is too short |
| `sink state changed` lines only | transitions happened without meeting the retrain condition; the sink was reporting lock while the panel was dark |

