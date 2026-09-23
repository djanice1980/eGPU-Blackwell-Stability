# pacman hooks

## amdgpu-frl-override-check (Sep 23, 2026)

Warning-only hook for the *other* out-of-tree module in this repo: the patched amdgpu built by
`tools/amdgpu-frl-module/build.sh`. That override lives in
`/usr/lib/modules/<ver>/updates/amdgpu-frl-lt/`, so a kernel update gives it a new `<ver>` and the
override silently stops applying — the stock driver comes back and the HDMI FRL loss-of-lock
recovery is simply gone, with nothing in the journal to say so. That is exactly what the
7.2.6 -> 7.2.7 update did on 2026-09-23.

    sudo bash install-amdgpu-frl-check.sh            # install
    sudo bash install-amdgpu-frl-check.sh --remove   # remove
    /usr/local/bin/amdgpu-frl-override-check         # run by hand any time; changes nothing

It runs PostTransaction on `linux-cachyos`/`-headers`, prints the affected kernel versions and the
exact commands to rebuild, and skips `*-lts` (the fallback kernel does not need the patch). It
deliberately does **not** build anything: that needs the matching kernel source under $HOME and a
network fetch, which do not belong in a pacman transaction.
