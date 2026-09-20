# Sending the HDMI FRL patch to amd-gfx

The email IS the patch file: `0001-drm-amd-display-Allow-300-ms-for-HDMI-FRL-link-training.amd-staging-drm-next.patch`
(rebased on AMD's `amd-staging-drm-next`, where the >= 16 Gbps relaxation it generalises
already lives; verified to apply there on Sep 19). No cover letter for a single patch.

Recipients (MAINTAINERS "AMD DISPLAY CORE" + the FRL author + the amdgpu maintainer):

    To:  amd-gfx@lists.freedesktop.org
    Cc:  Harry Wentland <harry.wentland@amd.com>, Leo Li <sunpeng.li@amd.com>,
         Rodrigo Siqueira <siqueira@igalia.com>, Alex Deucher <alexander.deucher@amd.com>,
         Fangzhi Zuo <Jerry.Zuo@amd.com>, dri-devel@lists.freedesktop.org

## One-time setup: git send-email over Gmail

`git send-email` ships with git on CachyOS as the `git` package's perl helper; if it says
"git: 'send-email' is not a git command", install `perl-authen-sasl perl-io-socket-ssl`:

    sudo pacman -S --needed perl-authen-sasl perl-io-socket-ssl

Gmail needs an *App Password* (Google Account -> Security -> 2-Step Verification -> App
passwords), not your normal password. Configure once (git asks for the app password at send
time; do not put it in the config):

    git config --global sendemail.smtpserver smtp.gmail.com
    git config --global sendemail.smtpserverport 587
    git config --global sendemail.smtpencryption tls
    git config --global sendemail.smtpuser djanice1980@gmail.com
    git config --global sendemail.confirm always

## Send

Run from any directory (a .patch file needs no repository):

    cd "/home/davidj/Claude Data/eGPU-Blackwell-Stability/kernel-patches"
    git send-email --to=amd-gfx@lists.freedesktop.org \
      --cc="Harry Wentland <harry.wentland@amd.com>" --cc="Leo Li <sunpeng.li@amd.com>" \
      --cc="Rodrigo Siqueira <siqueira@igalia.com>" --cc="Alex Deucher <alexander.deucher@amd.com>" \
      --cc="Fangzhi Zuo <Jerry.Zuo@amd.com>" --cc=dri-devel@lists.freedesktop.org \
      0001-drm-amd-display-Allow-300-ms-for-HDMI-FRL-link-training.amd-staging-drm-next.patch

It shows the full mail and asks `Send this email? [y/N/q/a]`. Gmail sends plain text as-is,
which is what the list requires (HTML mail is rejected).

## What to expect

Replies land on the list and in your inbox (you are the From:). Likely asks: a `Fixes:` tag
(none: the behaviour predates the FRL series' merge), whether a per-panel quirk is preferred
over a global change (answer: the sink is at the spec edge, not broken; 300 ms is what AMD
already grants for >= 16 Gbps and costs nothing on a healthy link), or a request for the
logs (`docs/logs/frl-lt-*.log` in this repo; the two pre-fix ones are the evidence).
Reply in plain text, quoting the line you answer; keep it short.
