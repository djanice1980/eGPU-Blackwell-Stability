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

## Sent

2026-09-19 20:30 CDT, from djanice1980@gmail.com via git send-email, SMTP result 250.
Message-ID `<20260920013050.21259-1-djanice1980@gmail.com>`. Archive:
https://lore.kernel.org/amd-gfx/20260920013050.21259-1-djanice1980@gmail.com/
Replies: on the list thread and in the Gmail inbox. A v2, if asked for, goes as a reply to
that Message-ID (`git send-email --in-reply-to=20260920013050.21259-1-djanice1980@gmail.com`)
with `[PATCH v2]` in the subject and a short changelog under the `---` line.

## Correction to send on the thread (Sep 20)

Today's evidence (runbook, Sep 20) contradicts one claim in the commit message: the overnight
"No Signal" persists with link training passing, so the LT timeout is not what caused the dark
wakes. The timeout and its fix are still real and measured. Reply to your own message with
`git send-email --in-reply-to=20260920013050.21259-1-djanice1980@gmail.com`, or plain-text
reply from Gmail keeping the To/Cc. Draft:

    Follow-up: I need to correct the dark-screen attribution in this commit
    message before anyone spends time on it. (Updated Sep 20 after catching the
    failure with instrumentation: the source is fully up while the sink reports
    No Signal, and the picture returns with no further source action.)

    With the patch applied, FRL link training does pass on the first attempt at
    10G x4 (7/7 DPMS cycles, no retries). But after an overnight DPMS standby the
    sink still came up "No Signal", and two further DPMS off/on cycles did not
    recover it, even though in both of them link training PASSED on the first
    try, the sink set FRL_START=1 in LTS:P (hdmi_frl_poll_start), and the stream
    was enabled with no error. Probing while the panel was dark showed the source
    scanning out normally: connector connected and dpms On, CRTC at 10 bpc with
    colorspace BT2020_RGB. The picture then returned by itself, more than 25 s
    later, with no further modeset or link activity from the source at all. So the
    long-standby dark screen looks like the sink (or the DP-to-HDMI FRL PCON)
    taking a long time to lock 4K120 10 bpc BT2020 after deep standby. It is a
    separate problem and this patch does not fix it.

    What the patch does fix is the measured timeout itself: with the 105-poll
    (~210 ms) budget this sink intermittently failed "Timeout waiting for
    FLT_UPDATE" at 10G x4, because the budget is not restarted when the sink
    raises its LTP request ~45 ms in and then takes ~180 ms to report lock.

    If you would prefer, I will send a v2 with the dark-wake paragraph dropped
    and no claim beyond the timeout.

