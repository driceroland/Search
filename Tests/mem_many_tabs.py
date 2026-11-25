#!/usr/bin/env python3
"""Search's own memory with many tabs: where it goes (mem-many-tabs).

Build first (`./build.sh`), then
`python3 Tests/mem_many_tabs.py [N ...] [--rounds R] [--idle S] [--heap] [--vmmap] [--dir D] [--out FILE]`.
PERF_APP=/path/to/Search.app times another build (a copy kept for before/after).

The world is perf_many_tabs.py's (three spaces, pins, groups, local pages),
started hidden the same way. Per N: the app's footprint (phys_footprint, as
Activity Monitor's Memory column shows it) and its RSS a few seconds after
restore and again after S seconds idle (default 30). With --dir, the
footprint's categories are kept there, and --vmmap adds the regions summary
(MALLOC, CoreAnimation, IOSurface, …), --heap the malloc zones' classes by
count and bytes (`heap -s`). MEM_HOLD=1 keeps the probe running until
Return (or until the file MEM_HOLD_FILE names is removed), for
`malloc_history PID -callTree` and the like: the app ignores
MallocStackLogging from its environment (hardened runtime), but those tools
turn the light stack logging on themselves when they attach.

Footprint, not RSS: RSS counts the frameworks' shared pages, the same in
every app, and is what the 271 MB measured in phase 1 was; Activity
Monitor's Memory column is the footprint.

Nothing here makes, shows, orders in or brings forward a window.
"""
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import perf_many_tabs as pmt  # noqa: E402

sv = pmt.sv


def launch():
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    env = ["--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_MEASURE=1"]
    subprocess.run(["open", "-n", "-g", "-j", *env, sv.APP])
    for _ in range(900):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.02)
    time.sleep(0.5)
    sv.started.update((sv.running() - before) & sv.holding())


def footprint(pid):
    out = subprocess.run(["footprint", "-p", str(pid)], capture_output=True, text=True).stdout
    m = re.search(r"Footprint:\s*([\d.]+)\s*([KMG]B)", out)
    if not m:
        return None, out
    v = float(m.group(1)) * {"KB": 1 / 1024, "MB": 1, "GB": 1024}[m.group(2)]
    return round(v, 1), out


def rss(pid):
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return round(int(out) / 1024, 1) if out else None


def vmmap(pid):
    out = subprocess.run(["vmmap", "--summary", str(pid)], capture_output=True, text=True).stdout
    rows = {}
    for line in out.splitlines():
        m = re.match(r"^(\S.*?)\s{2,}([\d.]+[KMG]?)\s+([\d.]+[KMG]?)\s+([\d.]+[KMG]?)\s+([\d.]+[KMG]?)", line)
        if m and not line.startswith("REGION"):
            rows[m.group(1).strip()] = {"virtual": m.group(2), "resident": m.group(3), "dirty": m.group(4), "swapped": m.group(5)}
    return rows, out


def heap(pid, top=40):
    out = subprocess.run(["heap", "-s", str(pid)], capture_output=True, text=True).stdout
    return out


def measure(n, rnd, idle, opts):
    out = {"n": n, "round": rnd}
    sv.setup(sidebar=True, spaces=True, **{"tabs.groups": True})
    pmt.world(n)
    launch()
    sv.cmd({"do": "resize", "width": 1280, "height": 820, "steps": 1})
    time.sleep(6)
    pid = pmt.app_pid()
    out["tabs"] = len(sv.cmd({"do": "tabs"})["tabs"])
    out["restoreMB"], _ = footprint(pid)
    out["restoreRSS"] = rss(pid)
    time.sleep(idle)
    out["idleMB"], fp = footprint(pid)
    out["idleRSS"] = rss(pid)
    tag = opts.get("tag", "m")
    d = opts.get("dir")
    if d:
        os.makedirs(d, exist_ok=True)
        Path(f"{d}/{tag}-{n}-{rnd}.footprint.txt").write_text(fp)
    if opts.get("vmmap"):
        rows, raw = vmmap(pid)
        if d:
            Path(f"{d}/{tag}-{n}-{rnd}.vmmap.txt").write_text(raw)
    if opts.get("heap"):
        raw = heap(pid)
        if d:
            Path(f"{d}/{tag}-{n}-{rnd}.heap.txt").write_text(raw)
    if opts.get("hold"):
        print(json.dumps(out), flush=True)
        print(f"holding pid {pid}; press Return to quit", file=sys.stderr, flush=True)
        if os.environ.get("MEM_HOLD_FILE"):
            Path(os.environ["MEM_HOLD_FILE"]).write_text(str(pid))
            while os.path.exists(os.environ["MEM_HOLD_FILE"]):
                time.sleep(1)
        else:
            sys.stdin.readline()
    sv.quit()
    return out


def main():
    args = sys.argv[1:]
    val = lambda k, d: args[args.index(k) + 1] if k in args else d
    rounds = int(val("--rounds", 1))
    idle = float(val("--idle", 30))
    outfile = val("--out", None)
    opts = {"vmmap": "--vmmap" in args, "heap": "--heap" in args, 
            "hold": os.environ.get("MEM_HOLD") == "1", "tag": val("--tag", "m"), "dir": val("--dir", None)}
    skip = {args.index(k) + 1 for k in ("--rounds", "--idle", "--out", "--tag", "--dir") if k in args}
    ns = [int(a) for i, a in enumerate(args) if a.isdigit() and i not in skip] or [50, 200, 400]
    try:
        for rnd in range(rounds):
            for n in (ns if rnd % 2 == 0 else list(reversed(ns))):
                res = measure(n, rnd, idle, opts)
                line = json.dumps(res)
                print(line, flush=True)
                if outfile:
                    with open(outfile, "a") as f:
                        f.write(line + "\n")
    finally:
        sv.finish()


if __name__ == "__main__":
    main()
