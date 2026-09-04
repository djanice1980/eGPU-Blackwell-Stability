#!/usr/bin/env bash
# If the plasmalogin greeter keeps leaving the LG external display dark until login:
# pin the GREETER's HDMI mode for that monitor to 3840x2160@60 (a non-FRL-marginal mode).
# Only touches the greeter's own KWin config (/var/lib/plasmalogin), not your session.
# Backs up first. Run with: sudo bash greeter-hdmi-4k60.sh    Revert: restore the .bak
set -euo pipefail
[ "$EUID" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }
F=/var/lib/plasmalogin/.config/kwinoutputconfig.json
[ -f "$F" ] || { echo "no greeter config at $F" >&2; exit 1; }
cp -a "$F" "$F.bak-$(date +%Y%m%d-%H%M)"
python3 - "$F" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); n=0
for entry in d:
    for o in entry.get('data',[]):
        if o.get('connectorName','').startswith('HDMI') and str(o.get('edidIdentifier','')).startswith('GSM 49352'):
            o['mode']={'width':3840,'height':2160,'refreshRate':60000}
            o['highDynamicRange']=False
            n+=1
json.dump(d,open(p,'w'),indent=4)
print(f"updated {n} greeter HDMI entr{'y' if n==1 else 'ies'} -> 3840x2160@60, HDR off")
PY
chown plasmalogin:plasmalogin "$F"
echo "Done. Takes effect at the next greeter start (reboot)."
