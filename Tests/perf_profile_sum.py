#!/usr/bin/env python3
"""Sum a Time Profiler export: the main thread's samples, by function.

`python3 Tests/perf_profile_sum.py OUT.trace [DSYM] [--top 40] [--match Search]`
Exports the time-profile table, keeps the main thread, and prints the
functions with the most inclusive and self samples (1 sample = 1 ms).
Addresses in Search's own binary that came without a name are looked up
in DSYM with atos.
"""
import collections
import re
import subprocess
import sys
import xml.etree.ElementTree as ET


def main():
    trace = sys.argv[1]
    dsym = sys.argv[2] if len(sys.argv) > 2 and not sys.argv[2].startswith("--") else None
    top = int(sys.argv[sys.argv.index("--top") + 1]) if "--top" in sys.argv else 40
    xml = subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath",
                          '/trace-toc/run/data/table[@schema="time-profile"]'], capture_output=True, text=True).stdout
    root = ET.fromstring(xml)
    ids = {}

    def resolve(el):
        if el is None:
            return None
        ref = el.get("ref")
        if ref:
            return ids.get(ref)
        if el.get("id"):
            ids[el.get("id")] = el
        for c in el:
            resolve(c)
        return el

    incl, selfc = collections.Counter(), collections.Counter()
    total = 0
    unnamed = {}
    for row in root.iter("row"):
        thread = resolve(row.find("thread"))
        tfmt = thread.get("fmt", "") if thread is not None else ""
        bt = resolve(row.find("backtrace") if row.find("backtrace") is not None else row.find("tagged-backtrace"))
        if bt is None:
            continue
        frames = []
        for f in bt.findall("frame"):
            f = resolve(f)
            if f is None:
                continue
            name = f.get("name") or f.get("addr")
            binary = resolve(f.find("binary"))
            bname = binary.get("name") if binary is not None else ""
            if (not f.get("name") or name.startswith("0x")) and bname == "Search" and binary is not None:
                unnamed[f.get("addr")] = binary.get("load-addr")
            frames.append((name, bname))
        if "Main Thread" not in tfmt and "main" not in tfmt.lower():
            continue
        total += 1
        seen = set()
        for name, b in frames:
            key = f"{name} [{b}]"
            if key not in seen:
                incl[key] += 1
                seen.add(key)
        if frames:
            selfc[f"{frames[0][0]} [{frames[0][1]}]"] += 1
    names = {}
    if dsym and unnamed:
        by_load = collections.defaultdict(list)
        for a, l in unnamed.items():
            by_load[l].append(a)
        for load, addrs in by_load.items():
            out = subprocess.run(["atos", "-o", dsym, "-l", load, *addrs], capture_output=True, text=True).stdout.splitlines()
            names.update(dict(zip(addrs, out)))

    def nm(k):
        m = re.match(r"(0x[0-9a-f]+) \[Search\]", k)
        return (names.get(m.group(1), k) + " [Search]") if m else k
    print(f"main thread samples: {total}")
    print("--- inclusive")
    for k, v in incl.most_common(top):
        print(f"{v:6d} {100 * v / max(total, 1):5.1f}%  {nm(k)[:200]}")
    print("--- self")
    for k, v in selfc.most_common(25):
        print(f"{v:6d} {100 * v / max(total, 1):5.1f}%  {nm(k)[:200]}")


main()
