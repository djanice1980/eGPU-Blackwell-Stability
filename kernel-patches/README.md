# Kernel patches (amdgpu)

Driver-side fixes found on this machine that are not (yet) upstream. Unlike `patches*/`
(NVIDIA open modules, applied by the pacman hook), these touch the in-tree amdgpu driver.

## 0001-drm-amd-display-Allow-300-ms-for-HDMI-FRL-link-train.patch (Sep 19, 2026)

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

## 0002-drm-amd-display-log-sink-SCDC-state-in-FRL-watchdog.patch (Sep 20, diagnostic)

Not a fix — instrumentation, and not for upstream as-is.

`hdmi_frl_status_polling_work()` polls every FRL link every 200 ms and retrains only when the
sink raises FLT_UPDATE. It ignores the return value of `link_query_ddc_data()`, so a sink that
has stopped answering reads back as all-zero flags and is indistinguishable from a happy one.
This patch captures that return value and additionally reads SCDC register 0x40, the sink's own
clock-detect and per-lane lock bits, logging one line per poll:

    FRL WATCHDOG: rate=5 update0[ddc=1]=0x00 (FRL_START=0 FLT_UPDATE=0) \
                  status[ddc=1]=0x1f (clk=1 ln0=1 ln1=1 ln2=1 ln3=1 flt_ready=0 dsc_fail=0)

How to read it on a dark morning (capture with `tools/hdmi-frl-watch.sh`):

| what you see | what it means |
|---|---|
| `ddc=0` on either read | the sink has stopped answering DDC entirely; the watchdog is blind and the source cannot know |
| `ddc=1`, `clk=1`, all `ln*=1` | the sink says it is locked to our signal while showing No Signal — the fault is inside the TV, past the link |
| `ddc=1`, `clk=0` or any `ln*=0` | the FRL link is actually down while the source believes it is up, and the sink is not raising FLT_UPDATE to ask for a retrain — that is a driver-actionable bug: the watchdog should retrain on loss of lock, not only on FLT_UPDATE |
| `dsc_fail=1` | the sink cannot decode the compressed stream |

Built into the same module override as 0001 (`tools/amdgpu-frl-module/build.sh` applies every
numbered patch here in order). drm_dbg, so it prints nothing until `drm.debug=0x2`.

