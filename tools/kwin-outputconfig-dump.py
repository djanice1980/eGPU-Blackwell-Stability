#!/usr/bin/env python3
# Print KWin's kwinoutputconfig.json (any of its schema variants) as a readable summary:
# every known output (connector, EDID id, mode) and every saved setup (lid state, per-output
# enabled/priority). Usage: sudo python3 kwin-outputconfig-dump.py [path]
import json, sys
path = sys.argv[1] if len(sys.argv) > 1 else "/var/lib/plasmalogin/.config/kwinoutputconfig.json"
d = json.load(open(path))

def section(name):
    if isinstance(d, dict):
        return d.get(name, [])
    for item in d:                       # list of {"name": ..., "data": [...]}
        if isinstance(item, dict) and item.get("name") == name:
            return item.get("data", [])
    return []

outs = section("outputs")
print(f"OUTPUTS ({len(outs)})")
for i, o in enumerate(outs):
    m = o.get("mode") or {}
    print(f"  [{i}] connector={o.get('connectorName')} edid={str(o.get('edidIdentifier',''))[:44]!r} "
          f"mode={m.get('width')}x{m.get('height')}@{m.get('refreshRate')} "
          f"hdr={o.get('highDynamicRange')} wcg={o.get('wideColorGamut')} vrr={o.get('vrrPolicy')} "
          f"scale={o.get('scale')}")
setups = section("setups")
print(f"SETUPS ({len(setups)})")
for n, s in enumerate(setups):
    print(f"  setup {n}: lidClosed={s.get('lidClosed')}")
    for x in s.get("outputs", []):
        print(f"     output[{x.get('outputIndex')}] enabled={x.get('enabled')} priority={x.get('priority')} pos={x.get('position')}")
