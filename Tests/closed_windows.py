#!/usr/bin/env python3
"""A window closed while another stays open is freed, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/closed_windows.py`. It uses
the split suite's harness: started hidden, nothing brought forward, and its
folder moved to the Trash afterwards. Each cycle opens a second window and
closes it: NSApp.windows must not grow, and every new window's traffic
lights must be where the first window's are — a new window can be given a
freed one's address, and Lights must not take it for the old one.
"""
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("closed-windows")

def trash():
    if os.path.exists(sv.SUPPORT):
        shutil.move(sv.SUPPORT, f"{sv.HOME}/.Trash/{os.path.basename(sv.SUPPORT)}.{time.time_ns()}")
    subprocess.run(["defaults", "delete", sv.SUITE], capture_output=True)
sv.wipe = trash

def windows(action, **f): return sv.cmd({"do": "windows", "action": action, **f})["windows"]
def alive(): return len(sv.cmd({"do": "probe"})["windows"])
def lights(n): return sv.cmd({"do": "probe", "window": n}).get("lights")

t = sv.T()
try:
    sv.setup(); sv.launch()
    first = lights(1)
    counts, misplaced = [], []
    for i in range(20):
        n = len(windows("new")); time.sleep(0.4)
        if lights(n) != first: misplaced.append((i + 1, lights(n)))
        windows("close", n=n); time.sleep(0.3)
        counts.append(alive())
    t.ok("closed windows are freed: NSApp.windows stays flat", counts[-1] <= counts[0], counts)
    t.ok("every new window's lights where the first's are", first and not misplaced, (first, misplaced))
    # The closed windows' key monitors are gone; a window's own still answers.
    windows("new"); windows("front", n=1)
    sv.cmd({"do": "press", "window": 2, "code": 37, "chars": "l", "mods": ["cmd"]}); time.sleep(0.6)
    fields = [sv.cmd({"do": "probe", "window": n}).get("field") for n in (1, 2)]
    t.ok("⌘L in the window behind opens its own field, not the front one's", fields == [False, True], fields)
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
