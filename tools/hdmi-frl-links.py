#!/usr/bin/env python3
"""Per-link table from hdmi-frl-switch-capture.sh logs: each trained link, its training timing, outcome.

Usage: python3 hdmi-frl-links.py ~/frl-switch-*.log
A link counts as LOCKED when the watchdog next logs status=0x5e; otherwise it shows how long it
lived before the next re-enable tore it down. Needs the drm.debug training lines (the capture tool
turns them on)."""
import re, sys
from datetime import datetime

def ts(line):
    m = re.match(r"\w+ \d+ (\d+:\d+:\d+\.\d+)", line)
    return datetime.strptime(m.group(1), "%H:%M:%S.%f") if m else None

for path in sys.argv[1:]:
    print(f"== {path.split('/')[-1]}")
    print(f"{'cycle':>5} {'link':>4} {'LTP5678->0 ms':>13} {'PASSED->START ms':>16} {'START polls':>11}  outcome")
    cyc = 0; links = []; cur = None
    lines = open(path).read().splitlines()
    for ln in lines + ["===== end"]:
        if ln.startswith("====="):
            for i, l in enumerate(links):
                print(f"{cyc:>5} {i:>4} {l.get('ltp','?'):>13} {l.get('p2s','?'):>16} {l.get('polls','?'):>11}  {l.get('out','never locked (torn down after %s s)' % l.get('life','?'))}")
            cyc += 1; links = []; cur = None
            continue
        t = ts(ln)
        if "Starting FRL Link Training" in ln:
            cur = {"start": t}; links.append(cur)
        elif cur is None:
            continue
        elif "LN0_LTP_REQ = 5" in ln and "ltp5" not in cur:
            cur["ltp5"] = t
        elif "LN0_LTP_REQ = 0" in ln and "ltp5" in cur and "ltp" not in cur:
            cur["ltp"] = int((t - cur["ltp5"]).total_seconds() * 1000)
        elif "LINK TRAINING:  PASSED" in ln:
            cur["passed"] = t
        elif "Read FRL_START = 1" in ln:
            cur["frlstart"] = t
            cur["polls"] = 100 - int(re.search(r"num_polls = (\d+)", ln).group(1))
            cur["p2s"] = int((t - cur["passed"]).total_seconds() * 1000) if "passed" in cur else "?"
        elif "re-enabling the link" in ln and "frlstart" in cur:
            cur["life"] = round((t - cur["frlstart"]).total_seconds(), 2)
        elif "status=0x5e" in ln and "sink state changed" in ln and "frlstart" in cur and "out" not in cur:
            cur["out"] = f"LOCKED {int((t - cur['frlstart']).total_seconds() * 1000)} ms after FRL_START"
