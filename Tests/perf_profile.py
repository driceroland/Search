#!/usr/bin/env python3
"""A Time Profiler trace of one many-tab scenario in a hidden probe.

`python3 Tests/perf_profile.py N SCENARIO OUT.trace` with SCENARIO one of
space (⌃2/⌃1 x10), select (revisits x20), newtab (open/close x10),
restore (attach right after launch), idle (10 s), scroll (column x6). The world is
perf_many_tabs.py's. xctrace attaches to the probe's pid only; nothing is
shown. Export afterwards with
`xcrun xctrace export --input OUT.trace --xpath '/trace-toc/run/data/table[@schema="time-profile"]'`.
"""
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import perf_many_tabs as pm  # noqa: E402

sv = pm.sv


def main():
    n, scenario, out = int(sys.argv[1]), sys.argv[2], sys.argv[3]
    sv.setup(sidebar=True, spaces=True, **{"tabs.groups": True})
    pm.world(n)
    pm.launch()
    sv.cmd({"do": "resize", "width": 1280, "height": 820, "steps": 1})
    time.sleep(4 if scenario != "restore" else 0)
    pid = pm.app_pid()
    secs = {"space": 16, "select": 22, "newtab": 16, "restore": 8, "idle": 10, "scroll": 16}[scenario]
    rec = subprocess.Popen(["xcrun", "xctrace", "record", "--template", "Time Profiler", "--attach", str(pid),
                            "--time-limit", f"{secs}s", "--output", out, "--no-prompt"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(2.5)
    count = len(sv.cmd({"do": "tabs"})["tabs"])
    if scenario == "space":
        for j in range(10):
            sv.cmd({"do": "spacetime", "index": 2 if j % 2 == 0 else 1})
    elif scenario == "select":
        picks = list(range(10, count - 1, max(1, (count - 11) // 10)))[:10]
        for i in picks:
            sv.cmd({"do": "perfselect", "index": i, "seconds": 0.3})
        for i in picks * 1:
            sv.cmd({"do": "perfselect", "index": i, "seconds": 0.3})
    elif scenario == "scroll":
        for j in range(6):
            sv.cmd({"do": "paceframes", "kind": "scroll", "stage": False, "dy": -14 if j % 2 == 0 else 14,
                    "steps": 40, "glide": 50})
    elif scenario == "newtab":
        for j in range(10):
            r = sv.cmd({"do": "open", "url": f"{pm.BASE}/p/new/{j}"})
            time.sleep(0.4)
            sv.cmd({"do": "close", "id": r["id"]})
            time.sleep(0.3)
    rec.wait()
    sv.quit()
    sv.finish()


if __name__ == "__main__":
    main()
