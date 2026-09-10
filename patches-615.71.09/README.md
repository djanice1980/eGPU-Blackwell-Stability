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
