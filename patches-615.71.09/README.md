# Patches ported to NVIDIA open-gpu-kernel-modules 615.71.09

Same six patches as `../patches/` (apnex E1, C2, C3, C4, C6 + the C5 crash-safety rebase),
re-based onto the `615.71.09` tag on 2026-09-10. Apply **in order** on a pristine checkout of
that tag; each later patch depends on the earlier ones (a `git apply --check *.patch` of the
whole set at once will report failures for that reason — verify one at a time).

Port notes (what changed between 610.57.04 and 615.71.09 in the touched code):
- `nv-pci.c`: NVIDIA added a deferred-probe context (`nv_pci_probe_deferred_context_t`,
  `nv_pci_probe_body()`, `nv_pci_wait_for_probe_complete()`) and a `PROBE_PREFER_ASYNCHRONOUS`
  selector on the pci_driver. C2's AER-unmask helper and C4's `.err_handler` now sit next to
  those; the C2 call site lives in `nv_pci_probe_body()`.
- `nv-pci.c`: NVIDIA guards `request_mem_region(BAR0)` with `!nv_pcie_is_cxl()`. C5's
  probe-time BAR-unset detector is placed before that guard and no longer duplicates the
  request_mem_region block.
- `nv.h` (both copies): NVIDIA added `cached_persistence_mode` to `nv_state_t`; C5's
  `gpu_lost_detector_logged` follows it.
- `kern_fsp_gh100.c`: NVIDIA added event-bus includes; C5's `nv-gpu-lost.h` include kept.
- E1, C3, C6 needed no changes. No upstream error-handling or lost-GPU teardown appeared in
  615 (checked), so every patch is still needed.

Build-verified 2026-09-10 against `7.2.3-1-cachyos` with `LLVM=1 CC=clang LD=ld.lld`:
0 errors, `modinfo` version 615.71.09. NOT yet runtime-tested (userspace still 610.57.04).
License: GPL-2.0, as `../patches/`.

## 07-C7-surprise-removal-unplug-guard-and-log-once (added 2026-09-16, ours)

Two things learned from a hard eGPU drop at game launch on 615 (see the runbook):
- `nvidia-drm`: `__nv_drm_master_set()` and `nv_drm_master_drop()` now return early when
  `drm_dev_is_unplugged(dev)`. After a surprise removal `nv_drm_remove()` has already called
  `drm_dev_unplug()` and NVKMS has torn the device down; the compositor closing its fd still
  went `master_drop → nvKmsKapiReleaseOwnership → nvkms_ioctl_from_kapi` and took a kernel
  GPF that killed kwin_wayland. C5's G10 guard covers `nv_drm_remove`, not this path.
- `intr.c`: the two "Failed GPU reg read" prints use `NV_GPU_LOST_LOG_ONCE`, and the two
  `NV_ASSERT_OK_OR_ELSE` on `_intrServiceStallCommonCheckBegin` return silently (logged once)
  when the status is `NV_ERR_GPU_IS_LOST`. The unguarded versions wrote 36k lines in one
  second and rotated the journal, destroying the evidence of what caused the drop.
Applies on top of 01–06. Build-verified on 7.2.5-1-cachyos. Not yet exercised by a real drop.


## 08-C8-lost-gpu-page-table-teardown (added 2026-09-30, ours)

This covers the lost-GPU path that C5 and C7 do not. On 2026-09-30 01:10:30 the Core X V2 link dropped
at idle. RM's virtual-memory teardown then kept walking the GPU page tables and invalidating TLBs of the
lost GPU. `_gmmuWalkCBFillEntries` could not map the page table (`pEntries == NULL`) and returned no
progress, and the walker asserted at every level. The result was ~11,800 lines in 0.3 s, of which
journald missed 4,969. The host then hard-locked, with no stack trace because `nowatchdog` was set.

Keyed on `PDB_PROP_GPU_IS_LOST`, and only in that state:

- the walker callbacks FillEntries, UpdatePde and CopyEntries report success without touching GPU
  memory, so the host-side bookkeeping completes;
- `gvaspaceInvalidateTlb` and the flush and invalidate in `_gvaspaceInternalFree` are skipped;
- `kgmmuInvalidateTlb_GM107` logs `NV_ERR_GPU_IS_LOST` once instead of on every call.

Each skipped path logs once.

Applies on top of 01-07; the whole set was verified to apply in order on a pristine 615.71.09 tag.
Build-verified on 7.2.8-1-cachyos (LLVM): 0 warnings in the touched files, and the objtool warning
count is unchanged from the Sep 27 build.

**Not proven to prevent the lockup.** It removes the flood and the hardware-touching work from
teardown; a real or deliberate drop will show whether the host now survives.
