#!/usr/bin/env python3
"""A profile that has grown: launch, new tab, address suggestions and tab switching against an empty one (profile-growth).

Build first (`./build.sh`), then
`python3 Tests/profile_growth.py [--rounds R] [--history N] [--bookmarks N] [--spaces N] [--out FILE]`
GROWTH_APP=/path/to/Search.app measures another build (a copy kept for before/after).

Two worlds one after the other, interleaved over the rounds: `empty` (a few
tabs, nothing else) and `large` (the same tabs, N history places (10,000 by
default: more than the 2,000 the file keeps), N bookmarks in folders (500),
and N spaces of pins with their own sessions (20 spaces of 5 pins = 100
pins)). The pages are perf_many_tabs.py's local ones.

Per world and round: the bench socket and the app's own launch marks
(didFinishLaunching, restored), what typing "git" and "pag" into the address
field cost key by key (inserted, rested), a new tab (the main thread's
longest pass and busy time over 0.8 s), tab switches across the row, a space
switch, and the app's footprint and the size of its files at rest.

Nothing here makes, shows, orders in or brings forward a window.
"""
import json
import os
import random
import statistics
import subprocess
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import perf_many_tabs as pmt  # noqa: E402

sv = pmt.sv
sv.use("profile-growth")
if os.environ.get("GROWTH_APP"):
    sv.APP = os.environ["GROWTH_APP"]


def history(n):
    rng = random.Random(7)
    now = time.time() - 978307200  # seconds since 2001, as a Swift Date is written
    out = []
    for i in range(n):
        host = f"site{i % 700}.example{i % 5}.com"
        url = f"https://{host}/section/{i % 90}/page-{i}"
        out.append({"url": url, "key": url.split("://", 1)[1], "title": f"Page {i} about topic {i % 97} on {host}",
                    "count": 1 + int(rng.random() ** 3 * 60), "last": now - rng.random() * 90 * 86400})
    return out


def bookmarks(n):
    folders = []
    per = max(n // 25, 1)
    for f in range(25):
        kids = [{"id": str(uuid.uuid4()).upper(), "title": f"Bookmark {f}.{i} on topic {i % 31}",
                 "url": f"https://bm{f}.example.org/doc/{i}"} for i in range(per)]
        folders.append({"id": str(uuid.uuid4()).upper(), "title": f"Folder {f}", "children": kids})
    return folders


def world(kind, hist, marks, spaces, tabs=12):
    os.makedirs(sv.SUPPORT, exist_ok=True)
    ids = [sv.FIRST_SPACE.upper()] + [f"5E4C0000-0000-4000-8000-{k:012X}" for k in range(1, max(spaces, 1))]
    if kind == "large":
        json.dump(history(hist), open(f"{sv.SUPPORT}/history.json", "w"))
        json.dump(bookmarks(marks), open(f"{sv.SUPPORT}/bookmarks.json", "w"))
    n = spaces if kind == "large" else 1
    json.dump([{"id": i, "name": f"S{k}", "colour": k % 8, "sharesSignIns": True} for k, i in enumerate(ids[:n])],
              open(f"{sv.SUPPORT}/spaces.json", "w"))
    for k, sid in enumerate(ids[:n]):
        entries = []
        for p in range(5 if kind == "large" else 0):
            entries.append({"url": f"{pmt.BASE}/p/pin{k}/{p}", "title": f"pin {k}.{p}", "pin": "ABCDE"[p],
                            "pinID": str(uuid.UUID(int=(k + 1) * 1000 + p)).upper(), "listed": p >= 2})
        for i in range(tabs if k == 0 else 3):
            entries.append({"url": f"{pmt.BASE}/p/s{k}/{i}", "title": f"space {k} tab {i}"})
        shape = {"tabs": entries, "active": len(entries) - 1}
        json.dump(shape, open(f"{sv.SUPPORT}/" + ("session.json" if k == 0 else f"session-{sid}.json"), "w"))


def du(path):
    total = 0
    for p in Path(path).rglob("*"):
        try:
            if p.is_file():
                total += p.stat().st_size
        except OSError:
            pass
    return round(total / 1048576, 2)


def round_of(kind, rnd, a):
    val = lambda k, d: int(a[a.index(k) + 1]) if k in a else d
    sv.setup(sidebar=True, spaces=True)
    world(kind, val("--history", 10000), val("--bookmarks", 500), val("--spaces", 20))
    out = {"world": kind, "round": rnd}
    sock = pmt.launch()
    time.sleep(4)
    log = sv.cmd({"do": "perfwatch", "seconds": 0.05})["log"]["marks"]
    out["socketMs"] = sock
    out["didFinishLaunching"] = log.get("didFinishLaunching")
    out["restored"] = log.get("restored")
    # Suggestions: typed a key at a time into the address field.
    for word in ("git", "pag", "topic 4"):
        r = sv.cmd({"do": "field", "text": word, "type": True})
        out[f"type_{word.replace(' ', '_')}"] = {"inserted": round(max(t[0] for t in r["ms"]), 1),
                                                  "rested": round(max(t[1] for t in r["ms"]), 1),
                                                  "offers": len(r["offers"])}
    time.sleep(1)
    opened = [sv.cmd({"do": "perftimed", "seconds": 0.8, "inner": {"do": "open", "url": f"{pmt.BASE}/p/new/{j}"}}) for j in range(5)]
    out["newtab"] = pmt.summ(opened)
    tabs = sv.cmd({"do": "tabs"})["tabs"]
    picks = list(range(1, min(len(tabs) - 1, 9)))
    sel = [sv.cmd({"do": "perfselect", "index": i, "seconds": 0.8}) for i in picks]
    sel += [sv.cmd({"do": "perfselect", "index": i, "seconds": 0.8}) for i in picks]
    out["select"] = pmt.summ(sel)
    if kind == "large":
        sw = []
        for j in range(6):
            r = sv.cmd({"do": "spacetime", "index": 2 if j % 2 == 0 else 1})
            ps_ = [p["ms"] for p in r["passes"]]
            sw.append({"callMs": r["callMs"], "longestMs": max(ps_), "busyMs": sum(ps_)})
            time.sleep(0.3)
        out["space"] = pmt.summ(sw[1:])
    pid = pmt.app_pid()
    out["appMB"] = round(pmt.ps([pid]).get(pid, (0, 0))[0])
    out["supportMB"] = du(sv.SUPPORT)
    sv.quit()
    return out


def main():
    a = sys.argv[1:]
    rounds = int(a[a.index("--rounds") + 1]) if "--rounds" in a else 3
    outfile = a[a.index("--out") + 1] if "--out" in a else None
    try:
        for rnd in range(rounds):
            for kind in ("empty", "large"):
                res = round_of(kind, rnd, a)
                print(json.dumps(res), flush=True)
                if outfile:
                    with open(outfile, "a") as f:
                        f.write(json.dumps(res) + "\n")
    finally:
        sv.finish()


if __name__ == "__main__":
    main()
