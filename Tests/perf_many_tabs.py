#!/usr/bin/env python3
"""Search with many tabs: 50, 100, 200, 400 — what each costs (perf-many-tabs).

Build first (`./build.sh`), then
`python3 Tests/perf_many_tabs.py [N ...] [--rounds R] [--arc] [--only restore,idle,...]`.

A hidden probe (SEARCH_PROBE=<world>, SEARCH_MEASURE=1 for shipped
throttling and App Nap, SEARCH_PERF=1 for PerfLog) starts on a session of N
loose tabs over three spaces (half, a third, the rest), each space with 6
pins (3 as rows) and a third of its tabs in groups of 6, one group folded:
the shape an Arc import makes. The pages come from a local server, a mix of
quiet ones: plain articles, a page with a clock and a poll, a mail-like page
whose title counts unread every 3 s, and a page with an animation.

Measured, per N:
- restore: launch to didFinishLaunching / restored / bench socket, and the
  main thread's passes over 16 ms in the first seconds (PerfLog).
- idle: 5 s with nothing done: the app's CPU, its passes; the web
  processes' CPU and memory (ps).
- select: tabs picked across the row, first visits (the page is built) and
  revisits: how long the pick held the main thread, the longest pass and
  the busy time over the 0.8 s after.
- newtab / close: a tab opened (bench open) and closed again.
- space: ⌃2 / ⌃1 (Bench spacetime), the longest pass and the busy time.
- scroll: the column scrolled (paceframes scroll, not staged: nothing is
  ordered in), the busy time and the longest pass.
- visited: idle again after the first-visit picks built pages.
- --arc: a made-up Arc (two profiles, two spaces each, folders, favourites,
  N tabs in all) brought in through the import, timed, then 8 s after.

Nothing here makes, shows, orders in or brings forward a window. Prints one
JSON line per N and round; --out FILE appends them there too.
"""
import json
import os
import random
import re
import statistics
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("perf-many-tabs")
# Another build of the app to time (a copy kept for before/after).
if os.environ.get("PERF_APP"):
    sv.APP = os.environ["PERF_APP"]
IDS = [sv.FIRST_SPACE.upper(), "5E4C0000-0000-4000-8000-0000000020B2", "5E4C0000-0000-4000-8000-0000000020B3"]
SHARE = [0.5, 0.3, 0.2]

# --- pages -----------------------------------------------------------------
def _png():
    import struct
    import zlib
    raw = b"".join(b"\x00" + b"\x20\x80\xf0\xff" * 16 for _ in range(16))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 16, 16, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


PNG = _png()
LOREM = ("Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et "
         "dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris. ")


def kind(i):
    k = i % 10
    return "static" if k < 6 else "timer" if k < 8 else "mail" if k == 8 else "anim"


def page(path):
    m = re.match(r"/p/(\w+)/(\d+)", path)
    name, i = (m.group(1), int(m.group(2))) if m else ("x", 0)
    k = kind(i)
    paras = "".join(f"<h2>Section {s}</h2><p>{LOREM * 6}</p>" for s in range(20))
    head = f"<link rel=icon href='/icon/{name}-{i}.png'>"
    script = ""
    if k == "timer":
        script = ("<div id=clock></div><script>setInterval(()=>{clock.textContent=new Date().toISOString()},1000);"
                  "setInterval(()=>fetch('/ping').catch(()=>{}),15000)</script>")
    elif k == "mail":
        script = ("<script>let n=0;setInterval(()=>{n=(n+1)%40;document.title=`(${n}) Inbox — "
                  f"{name} {i}`" "},3000)</script>")
    elif k == "anim":
        script = ("<div id=b style='width:300px;height:60px;background:#08f'></div><script>"
                  "(function f(t){b.style.transform=`translateX(${(t/10)%200}px)`;requestAnimationFrame(f)})(0)</script>")
    return f"<!doctype html><html><head><meta charset=utf-8><title>{name} {i} {k}</title>{head}</head><body>{script}{paras}</body></html>".encode()


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/icon/"):
            body, ctype = PNG, "image/png"
        elif self.path == "/ping":
            body, ctype = b"ok", "text/plain"
        else:
            body, ctype = page(self.path), "text/html"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "max-age=3600")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a): pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"


# --- the world -------------------------------------------------------------
def counts(n):
    a = [int(n * s) for s in SHARE]
    a[0] += n - sum(a)
    return a


def world(n):
    os.makedirs(sv.SUPPORT, exist_ok=True)
    json.dump([{"id": i, "name": f"S{k}", "colour": k + 2, "sharesSignIns": True} for k, i in enumerate(IDS)],
              open(f"{sv.SUPPORT}/spaces.json", "w"))
    for k, (sid, loose) in enumerate(zip(IDS, counts(n))):
        tabs, groups = [], []
        for p in range(6):
            tabs.append({"url": f"{BASE}/p/pin{k}/{p}", "title": f"pin {k}.{p}", "pin": "ABCDEF"[p],
                         "pinID": str(uuid.UUID(int=(k + 1) * 1000 + p)).upper(), "listed": p >= 3})
        grouped = loose // 3
        for i in range(loose):
            e = {"url": f"{BASE}/p/s{k}/{i}", "title": f"space {k} tab {i}, a title of a usual length"}
            if i < grouped:
                g = i // 6
                if g == len(groups):
                    groups.append({"id": str(uuid.UUID(int=(k + 1) * 100000 + g)).upper(), "name": f"Folder {g}",
                                   "collapsed": g == 1})
                e["groupID"] = groups[g]["id"]
            tabs.append(e)
        shape = {"tabs": tabs, "active": len(tabs) - 1, "groups": groups}
        json.dump(shape, open(f"{sv.SUPPORT}/" + ("session.json" if k == 0 else f"session-{sid}.json"), "w"))


def arc(n):
    """A made-up Arc: profiles Default and Profile 1, two spaces each, N
    tabs in all, a third in folders of 6, 4 favourites per profile."""
    root = f"{sv.SUPPORT}/Import/Arc"
    for prof in ("Default", "Profile 1"):
        os.makedirs(f"{root}/User Data/{prof}", exist_ok=True)
        Path(f"{root}/User Data/{prof}/History").write_bytes(b"")
    Path(f"{root}/User Data/Local State").write_text(json.dumps({"profile": {"info_cache": {
        "Default": {"name": "Personal"}, "Profile 1": {"name": "Work"}}}}))
    items, spaces, tops = [], [], []
    per = [n // 4] * 4
    per[0] += n - sum(per)
    for s, count in enumerate(per):
        prof = {"default": {}} if s < 2 else {"custom": {"_0": {"directoryBasename": "Profile 1"}}}
        box = f"pin-{s}"
        kids, folder = [], None
        for i in range(count):
            tid = f"{box}-t{i}"
            items.append({"id": tid, "title": f"arc {s} {i}", "data": {"tab": {"savedURL": f"{BASE}/p/arc{s}/{i}",
                                                                               "savedTitle": f"arc {s} {i}"}}})
            if i < count // 3:
                if i % 6 == 0:
                    folder = {"id": f"{box}-f{i}", "title": f"Folder {i // 6}", "data": {"list": {}}, "childrenIds": []}
                    items.append(folder)
                    kids.append(folder["id"])
                folder["childrenIds"].append(tid)
            else:
                kids.append(tid)
        items.append({"id": box, "childrenIds": kids})
        spaces.append({"title": f"Arc {s}", "profile": prof, "containerIDs": ["pinned", box]})
    for p, prof in enumerate(({"default": {}}, {"custom": {"_0": {"directoryBasename": "Profile 1"}}})):
        fav = f"fav-{p}"
        kids = [f"{fav}-{j}" for j in range(4)]
        for j, kid in enumerate(kids):
            items.append({"id": kid, "title": f"fav {p}.{j}", "data": {"tab": {"savedURL": f"{BASE}/p/fav{p}/{j}",
                                                                              "savedTitle": f"fav {p}.{j}"}}})
        items.append({"id": fav, "childrenIds": kids})
        tops += [prof, fav]
    sidebar = {"sidebar": {"containers": [{"spaces": spaces, "items": items, "topAppsContainerIDs": tops}]}}
    Path(f"{root}/StorableSidebar.json").write_text(json.dumps(sidebar))


# --- the probe -------------------------------------------------------------
def launch():
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    t0 = time.time()
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_MEASURE=1",
                    "--env", "SEARCH_PERF=1", sv.APP])
    for _ in range(600):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.02)
    sock = time.time() - t0
    time.sleep(0.5)
    sv.started.update((sv.running() - before) & sv.holding())
    return round(sock * 1000)


def app_pid():
    p = sv.pids()
    return int(p[0]) if p else 0


def ps(pids):
    """{pid: (rss MB, cpu seconds)} for those still running."""
    pids = [str(p) for p in pids if p]
    if not pids:
        return {}
    out = subprocess.run(["ps", "-o", "pid=,rss=,time=", "-p", ",".join(pids)], capture_output=True, text=True).stdout
    got = {}
    for line in out.splitlines():
        pid, rss, t = line.split()
        parts = [float(x) for x in t.replace("-", ":").split(":")]
        secs = 0.0
        for x in parts:
            secs = secs * 60 + x
        got[int(pid)] = (int(rss) / 1024, secs)
    return got


def watch(seconds=5.0):
    """Idle for `seconds`: the app's own record, and the web processes'."""
    pre = sv.cmd({"do": "perfwatch", "seconds": 0.05})
    helpers = pre["webPids"] + [pre["gpu"], pre["network"]]
    before = ps(helpers + [app_pid()])
    w = sv.cmd({"do": "perfwatch", "seconds": seconds})
    helpers = sorted(set(helpers + w["webPids"] + [w["gpu"], w["network"]]))
    after = ps(helpers + [app_pid()])
    app = app_pid()
    web = [p for p in w["webPids"] if p in after]
    webcpu = sum(after[p][1] - before.get(p, (0, after[p][1]))[1] for p in web)
    other = [p for p in (w["gpu"], w["network"]) if p in after]
    return {"appCpuPct": round(w["cpuMs"] / seconds / 10, 1), "webCpuPct": round(webcpu / seconds * 100, 1),
            "helperCpuPct": round(sum(after[p][1] - before.get(p, (0, after[p][1]))[1] for p in other) / seconds * 100, 1),
            "longestMs": w["longestMs"], "over16": w["over16"], "over50": w["over50"], "busyMs": w["busyMs"],
            "passes": w["passes"], "appMB": round(after.get(app, (0, 0))[0]), "webMB": round(sum(after[p][0] for p in web)),
            "helperMB": round(sum(after[p][0] for p in other)), "webProcs": len(web), "built": w["built"],
            "inRows": w["inRows"], "asleep": w["asleep"]}


def med(xs):
    return round(statistics.median(xs), 1) if xs else None


def summ(rs, keys=("callMs", "longestMs", "busyMs")):
    return {k: med([r[k] for r in rs]) for k in keys} | {"maxLongestMs": max((r["longestMs"] for r in rs), default=None)}


ONLY = None


def want(name):
    return ONLY is None or name in ONLY


def measure(n, rnd):
    out = {"n": n, "round": rnd}
    sv.setup(sidebar=True, spaces=True, **{"tabs.groups": True})
    world(n)
    sockMs = launch()
    sv.cmd({"do": "resize", "width": 1280, "height": 820, "steps": 1})
    time.sleep(4)
    log = sv.cmd({"do": "perfwatch", "seconds": 0.05})["log"]
    marks = log["marks"]
    out["restore"] = {"socketMs": sockMs, "didFinishLaunching": marks.get("didFinishLaunching"),
                      "restored": marks.get("restored"), "restoreMs": round(marks.get("restored", 0) - marks.get("restoreStart", 0), 1),
                      "launchLongestMs": max((l[1] for l in log["long"]), default=0),
                      "launchOver50": sum(1 for l in log["long"] if l[1] > 50),
                      "launchBusyMs": log["busyMs"]}
    time.sleep(2)
    if want("idle"):
        out["idle"] = watch(5)
    st = sv.cmd({"do": "tabs"})["tabs"]
    count = len(st)
    rng = random.Random(n * 7 + rnd)
    picks = sorted(rng.sample(range(6, count - 1), min(12, count - 7)))
    if want("select"):
        first = [sv.cmd({"do": "perfselect", "index": i, "seconds": 0.8}) for i in picks]
        again = [sv.cmd({"do": "perfselect", "index": i, "seconds": 0.8}) for i in picks[:6]]
        pins = [sv.cmd({"do": "perfselect", "index": i, "seconds": 0.8}) for i in range(3)]
        out["selectFirst"] = summ(first)
        out["selectAgain"] = summ(again)
        out["selectPin"] = summ(pins)
    if want("newtab"):
        opened = []
        for j in range(5):
            r = sv.cmd({"do": "perftimed", "seconds": 0.8, "inner": {"do": "open", "url": f"{BASE}/p/new/{j}"}})
            opened.append(r)
        closed = [sv.cmd({"do": "perftimed", "seconds": 0.8, "inner": {"do": "close", "id": r["reply"]["id"]}}) for r in opened]
        out["newtab"] = summ(opened)
        out["close"] = summ(closed)
    if want("space"):
        sw = []
        for j in range(6):
            r = sv.cmd({"do": "spacetime", "index": 2 if j % 2 == 0 else 1})
            ps_ = [p["ms"] for p in r["passes"]]
            sw.append({"callMs": r["callMs"], "longestMs": max(ps_), "busyMs": sum(ps_), "rows": sum(p["rows"] for p in r["passes"])})
            time.sleep(0.3)
        out["space"] = summ(sw[1:]) | {"rows": med([s["rows"] for s in sw[1:]])}
    if want("scroll"):
        sc = []
        for j in range(4):
            r = sv.cmd({"do": "paceframes", "kind": "scroll", "stage": False, "dy": -14 if j % 2 == 0 else 14,
                        "steps": 40, "glide": 50})
            sc.append({"callMs": r["stepMedianMs"], "longestMs": r["longestPass"], "busyMs": r["busyMs"], "rows": r["rows"]})
            time.sleep(0.3)
        out["scroll"] = summ(sc) | {"rows": med([s["rows"] for s in sc])}
    if want("visited"):
        # Every page first-visited above is built: idle again.
        time.sleep(3)
        out["visited"] = watch(5)
    sv.quit()
    return out


def measure_arc(n, rnd):
    out = {"n": n, "round": rnd, "arc": True}
    sv.setup(sidebar=True, **{"start.fresh": False, "tabs.groups": True})
    arc(n)
    launch()
    sv.cmd({"do": "resize", "width": 1280, "height": 820, "steps": 1})
    time.sleep(3)
    base_long = len(sv.cmd({"do": "perfwatch", "seconds": 0.05})["log"]["long"])
    r = sv.cmd({"do": "perftimed", "seconds": 8, "inner": {"do": "import", "from": "Arc", "what": ["spaces"], "profile": "all"}})
    log = sv.cmd({"do": "perfwatch", "seconds": 0.05})["log"]
    after = log["long"][base_long:]
    a = r["reply"].get("arc") or {}
    out["import"] = {"callMs": r["callMs"], "longestMs": r["longestMs"], "busyMs": r["busyMs"], "over50": r["over50"],
                     "cpuMs": r["cpuMs"], "spaces": a.get("spaces"), "tabs": a.get("tabs"),
                     "longPasses": len(after)}
    out["after"] = watch(5)
    sw = []
    sp = sv.cmd({"do": "space"})
    for j in range(4):
        r = sv.cmd({"do": "spacetime", "index": 2 if j % 2 == 0 else 1})
        ps_ = [p["ms"] for p in r["passes"]]
        sw.append({"callMs": r["callMs"], "longestMs": max(ps_), "busyMs": sum(ps_)})
    out["space"] = summ(sw[1:]) | {"spaces": len(sp.get("spaces", [])) if isinstance(sp.get("spaces"), list) else sp.get("spaces")}
    sv.quit()
    return out


def main():
    global ONLY
    args = sys.argv[1:]
    rounds = int(args[args.index("--rounds") + 1]) if "--rounds" in args else 1
    outfile = args[args.index("--out") + 1] if "--out" in args else None
    if "--only" in args:
        ONLY = set(args[args.index("--only") + 1].split(","))
    ns = [int(a) for a in args if a.isdigit() and (args.index(a) == 0 or args[args.index(a) - 1] not in ("--rounds",))]
    ns = ns or [50, 100, 200, 400]
    try:
        for rnd in range(rounds):
            # Interleaved: every N once a round, the order turned each round.
            for n in (ns if rnd % 2 == 0 else list(reversed(ns))):
                res = measure_arc(n, rnd) if "--arc" in args else measure(n, rnd)
                line = json.dumps(res)
                print(line, flush=True)
                if outfile:
                    with open(outfile, "a") as f:
                        f.write(line + "\n")
    finally:
        sv.finish()


if __name__ == "__main__":
    main()
