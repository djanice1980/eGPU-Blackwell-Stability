# Patches for NVIDIA open-gpu-kernel-modules 615.78.08

These are the same eight patches as `../patches-615.71.09/` (E1, C2, C3, C4, C6, C5, C7, C8), copied
unchanged. They were ported on 2026-10-07, ahead of the 615.78.08 `nvidia-utils` package reaching the
CachyOS/Arch repos, so the `nvidia-egpu-rebuild` hook finds this set when that update lands instead of
falling back to an unpatched driver. The `06-C5-crash-safety-615.71.09.patch` name is kept for
traceability; its content applies to 615.78.08 as-is.

## Port check

- **Applies:** all eight apply cleanly, in order, to a pristine `615.78.08` tag (`git apply`, no 3-way
  needed).
- **Overlap with NVIDIA's changes:** the 615.71.09 -> 615.78.08 diff touches 7 of the 41 files we
  patch, none of them in our hunks:
  - `os-interface.c`: newer-kernel compatibility (`shmem_kernel_file_setup`, dmem cgroup init API);
  - `kernel_falcon_tu102.c`: RISC-V trace-buffer bounds hardening;
  - `intr.c`: GSP interrupt subtree-map validation;
  - `osapi.c`: event free formatting;
  - `mem.c`, `rs_server.c`, `rpc.c`: trivial changes.
  - Elsewhere: a sysmem lock-release fix on error paths, and a DP hotplug warning downgraded to not
    print on every plug.
- **No upstream lost-GPU work:** NVIDIA added no lost-GPU or surprise-removal handling, so every patch
  is still needed and none is duplicated.
- **Build:** verified 2026-10-07 against `7.2.9-1-cachyos` (clang 23.1.1, `LLVM=1 CC=clang LD=ld.lld`).
  - The modules report version 615.78.08 and vermagic 7.2.9-1-cachyos.
  - The C8 log strings (3) and the E1 Thunderbolt detection are present.
  - There are 97 non-objtool compiler warnings and 9,230 objtool warnings. That matches the hook's
    615.71.09 build for the same kernel and toolchain (97). The three warnings in files we patch
    (`nv.c` `hi_val`, two `-Wformat-security` in `os-interface.c`) are NVIDIA's own code and were
    present before the port.
- **Runtime:** not yet tested. It runs once `nvidia-utils` 615.78.08 is installed and the hook ports
  the tree.
