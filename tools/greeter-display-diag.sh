#!/usr/bin/env bash
# Why did the plasmalogin greeter leave the external HDMI display dark until login?
# Dumps the greeter's own KWin output config and its KWin log lines for this boot.
# Run with: sudo bash greeter-display-diag.sh
set -u
[ "$EUID" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }
GUID=$(id -u plasmalogin 2>/dev/null || echo 957)
echo "=== plasmalogin.conf (non-comment lines) ==="
grep -vE '^\s*#|^\s*$' /etc/plasmalogin.conf 2>/dev/null
echo
echo "=== greeter kwinoutputconfig.json: HDMI entries (mode / enabled / hdr) ==="
F=/var/lib/plasmalogin/.config/kwinoutputconfig.json
if [ -f "$F" ]; then
  ls -la --time-style=long-iso "$F"
  python3 - "$F" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for entry in d:
    outs=entry.get('data',[])
    names=[o.get('name','?') for o in outs]
    print('config set with outputs:',names)
    for o in outs:
        m=o.get('mode',{})
        print('  ',o.get('name'),'enabled=',o.get('enabled'),'mode=',m.get('width'),'x',m.get('height'),'@',m.get('refreshRate'),
              'hdr=',o.get('highDynamicRange'),'wcg=',o.get('wideColorGamut'),'vrr=',o.get('vrrPolicy'),'priority=',o.get('priority'))
PY
else
  echo "(no greeter kwinoutputconfig.json -> greeter uses KWin defaults: all connected outputs enabled)"
fi
echo
echo "=== greeter session (uid $GUID) log lines this boot: kwin / outputs / drm ==="
journalctl -b _UID="$GUID" -o short-monotonic 2>/dev/null | grep -iE "kwin|output|HDMI|eDP|drm|mode|hotplug|connector" | head -40
echo
echo "=== greeter session: everything from kwin_wayland (last 30) ==="
journalctl -b _UID="$GUID" _COMM=kwin_wayland -o short-monotonic 2>/dev/null | tail -30
