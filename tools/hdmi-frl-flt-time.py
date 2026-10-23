#!/usr/bin/env python3
"""Per-training FLT_UPDATE loop time from hdmi-frl-switch-capture logs (drm.debug=0x2).

Time runs from "Poll for FLT_UPDATE" (logged just before the timed loop, in our 0001 build and in
AMD's ae5df7bc/d6751306 code alike) to the training's PASSED or FAILED line -- the quantity AMD's
code compares against poll_timeout_ns. Prints the distribution and how many trainings would
exceed a given budget, plus the FAILED - Timeout count.

  python3 hdmi-frl-flt-time.py ~/frl-switch-*.log
"""
import re
import sys
from datetime import datetime

TS = re.compile(r"^(\w{3} +\d+ \d\d:\d\d:\d\d\.\d+)")


def stamp(m):
    return datetime.strptime("2026 " + " ".join(m.group(1).split()), "%Y %b %d %H:%M:%S.%f")


for path in sys.argv[1:]:
    passed, failed = [], []
    start = None
    for line in open(path, errors="replace"):
        m = TS.match(line)
        if not m:
            continue
        if "Starting FRL Link Training" in line:
            start = None
        elif "Poll for FLT_UPDATE" in line:
            start = stamp(m)
        elif start and "LINK TRAINING:  PASSED" in line:
            passed.append((stamp(m) - start).total_seconds() * 1000)
            start = None
        elif start and "FAILED - Timeout waiting for FLT_UPDATE" in line:
            failed.append((stamp(m) - start).total_seconds() * 1000)
            start = None
    print(f"== {path.rsplit('/', 1)[-1]}")
    n = len(passed) + len(failed)
    print(f"   trainings: {n}   PASSED {len(passed)}   FAILED-timeout {len(failed)}"
          + (f" ({100 * len(failed) / n:.0f}%)" if n else ""))
    if passed:
        p = sorted(passed)
        q = lambda f: p[min(len(p) - 1, int(f * len(p)))]
        print(f"   PASSED loop time: min {p[0]:.0f}  median {q(0.5):.0f}  p90 {q(0.9):.0f}  max {p[-1]:.0f} ms")
        for lim in (200, 220, 250, 300):
            over = sum(1 for x in p if x > lim)
            print(f"     over {lim} ms: {over}")
    if failed:
        f = sorted(failed)
        print(f"   FAILED after: {', '.join(f'{x:.0f}' for x in f)} ms")
