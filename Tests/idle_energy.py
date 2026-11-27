#!/usr/bin/env python3
"""What an idle Search costs in energy: CPU time and wakeups of every process, over time (idle-energy).

Build first (`./build.sh`), then
`python3 Tests/idle_energy.py [--tabs 1,10,40] [--secs 60] [--settle 20] [--nap on|off] [--plain] [--rounds R] [--out FILE]`
`python3 Tests/idle_energy.py --long 600 [--tabs 10]` samples every 30 s for 10 minutes.
`--bitwarden` installs Bitwarden from the store first (signed out, never touched; Search only).
`--youtube VIDEO` adds a YouTube watch tab (needs the network), muted at the source (the tab, the player,
the element: nothing plays until all three say muted) and asked to play; the result says whether it did.
IDLE_APP=/path/to/Search.app measures another build (a copy kept for before/after).

A hidden probe in a world of its own (split_view.py's harness) opens N tabs
of quiet local articles through the bench, lets the app settle, and samples
Search and everything it is responsible for (the WebContent, GPU and
Networking processes) with proc_pid_rusage: CPU time, idle wakeups,
interrupt wakeups, instructions and billed energy, as deltas over --secs.

--nap on (the default) starts the probe as people get it (SEARCH_MEASURE=1:
hidden pages slowed the way WebKit slows them, App Nap left to macOS). A
visible window is never napped, so --nap off holds App Nap off for the
whole app, which is the main process as it is with its window on screen;
the pages then also run unslowed, so read the web processes from --nap on.

--plain holds the same pages in a bare WKWebView each, in an app with no
window (perf_tools.py's plainweb, a few lines of Objective-C), for
the floor to compare Search's own and its helpers' numbers with.

Nothing here makes, shows, orders in or brings forward a window.
"""
import json
import os
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import perf_tools  # noqa: E402
import split_view as sv  # noqa: E402

sv.use("idle-energy")
if os.environ.get("IDLE_APP"):
    sv.APP = os.environ["IDLE_APP"]
LOREM = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore. "


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = (f"<!doctype html><title>Article {self.path}</title><body>"
                + "".join(f"<h2>Section {s}</h2><p>{LOREM * 6}</p>" for s in range(12))).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"


def sample(pid, secs):
    return perf_tools.sample(pid, secs)


def kind(name):
    n = name.lower()
    if "webcontent" in n:
        return "web"
    if "gpu" in n:
        return "gpu"
    if "networking" in n:
        return "net"
    return "app"


def fold(s):
    """Per kind: CPU % of a core, idle wakeups/s, interrupt wakeups/s, energy nJ/s, MB, process count."""
    secs = s["secs"]
    rows = {}
    for p in s["procs"]:
        r = rows.setdefault(kind(p["name"]), {"cpu": 0.0, "idle": 0, "intr": 0, "nj": 0, "mb": 0.0, "n": 0})
        r["cpu"] += p["cpu_ms"] / (secs * 10)
        r["idle"] += p["wk_idle"] / secs
        r["intr"] += p["wk_intr"] / secs
        r["nj"] += p["energy_nj"] / secs
        r["mb"] += p["mb"]
        r["n"] += 1
    for r in rows.values():
        for k in ("cpu", "idle", "intr", "nj", "mb"):
            r[k] = round(r[k], 2)
    rows["all"] = {k: round(sum(r[k] for r in rows.values()), 2) for k in ("cpu", "idle", "intr", "nj", "mb")}
    return rows


def launch(nap):
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    env = ["--env", f"SEARCH_PROBE={sv.W}"] + (["--env", "SEARCH_MEASURE=1"] if nap else [])
    subprocess.run(["open", "-n", "-g", "-j", *env, sv.APP])
    for _ in range(600):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.05)
    time.sleep(1)
    sv.started.update((sv.running() - before) & sv.holding())
    pids = sv.pids()
    if not pids:
        sys.exit("Search didn't start")
    return int(pids[0])


YT = None  # a YouTube video id, from --youtube
MUTE = """(function () { var p = document.getElementById('movie_player'); try { if (p && p.mute) { p.mute(); p.setVolume(0); } } catch (e) {}
  var v = document.querySelector('video'); if (v) { v.muted = true; v.volume = 0; } return !!(v && v.muted && v.volume === 0); })()"""
PLAY = """(function () { var p = document.getElementById('movie_player'); var v = document.querySelector('video');
  if (!v || !v.muted) return 'not muted'; try { if (p && p.playVideo) p.playVideo(); else v.play(); } catch (e) {}
  return v.paused ? 'paused' : 'playing'; })()"""


def start_youtube():
    """A YouTube tab, muted at the source (the tab, the player, the element) before anything plays."""
    tab = sv.cmd({"do": "open", "url": f"https://www.youtube.com/watch?v={YT}"})["id"]
    sv.cmd({"do": "mute", "id": tab})
    if not next(t for t in sv.cmd({"do": "tabs"})["tabs"] if t["id"] == tab).get("muted"):
        sys.exit("the tab didn't report muted: not playing anything")
    sv.cmd({"do": "wait", "id": tab, "seconds": 30})
    for _ in range(40):
        if sv.ev(tab, MUTE) is True:
            break
        time.sleep(0.5)
    else:
        sys.exit("the player never reported muted: not playing anything")
    state = "?"
    for _ in range(20):
        state = sv.ev(tab, PLAY)
        if state == "playing":
            break
        time.sleep(1)
    return tab, state


BITWARDEN = "nngceckbapebfimnlniiiahkandclblb"
EXT = False  # from --bitwarden


def install_bitwarden():
    """Bitwarden from the store, signed out: nothing typed into it, ever."""
    sv.cmd({"do": "ext-add", "id": BITWARDEN, "yes": True})
    for _ in range(120):
        time.sleep(1)
        got = [e for e in sv.cmd({"do": "extensions"})["extensions"] if e["id"] == BITWARDEN]
        if got and got[0]["loaded"]:
            return got[0]["name"]
    sys.exit("Bitwarden never loaded")


def search_round(n, secs, settle, nap, long=0):
    sv.setup()
    pid = launch(nap)
    ids = []
    yt_state = None
    if EXT:
        install_bitwarden()
    if YT:
        _, yt_state = start_youtube()
    for i in range(n):
        ids.append(sv.cmd({"do": "open", "url": f"{BASE}/a/{i}"})["id"])
    for i in ids:
        sv.cmd({"do": "wait", "id": i, "seconds": 20})
    time.sleep(settle)
    if long:
        series = []
        for _ in range(int(long // 30)):
            series.append(fold(sample(pid, 30)))
        out = {"series": series}
    else:
        out = fold(sample(pid, secs))
    # Never a window of it on a screen: a probe that showed one is no result.
    out["tabs"] = n
    if YT:
        out["youtube"] = yt_state
    sv.quit()
    return out


def plain_round(n, secs, settle, nap):
    lst = tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False)
    urls = ([f"https://www.youtube.com/watch?v={YT}"] if YT else []) + [f"{BASE}/a/{i}" for i in range(max(n, 1))]
    lst.write("\n".join(urls))
    lst.close()
    # An app of its own (so its helpers are its own, as Search's are).
    subprocess.run(["open", "-n", "-g", "-j", perf_tools.plainweb_app(), "--args", lst.name] + (["nonap"] if not nap else []))
    for _ in range(100):
        pid = subprocess.run(["pgrep", "-x", "plainweb"], capture_output=True, text=True).stdout.split()
        if pid:
            break
        time.sleep(0.1)
    pid = int(pid[0])
    time.sleep(settle + 4)
    out = fold(sample(pid, secs))
    out["tabs"] = n
    subprocess.run(["kill", str(pid)])
    time.sleep(2)
    return out


def main():
    a = sys.argv[1:]
    val = lambda k, d: a[a.index(k) + 1] if k in a else d
    tabs = [int(x) for x in val("--tabs", "1,10,40").split(",")]
    secs, settle = float(val("--secs", 60)), float(val("--settle", 20))
    nap = val("--nap", "on") == "on"
    long = float(val("--long", 0))
    global YT, EXT
    YT = val("--youtube", None)
    EXT = "--bitwarden" in a
    rounds = int(val("--rounds", 1))
    outfile = val("--out", None)
    try:
        for n in tabs:
            for r in range(rounds):
                for who in (["search", "plain"] if "--plain" in a else ["search"]):
                    res = (search_round if who == "search" else plain_round)(n, secs, settle, nap, *([long] if who == "search" else []))
                    res.update(who=who, nap=nap, round=r)
                    print(json.dumps(res), flush=True)
                    if outfile:
                        with open(outfile, "a") as f:
                            f.write(json.dumps(res) + "\n")
    finally:
        sv.finish()


if __name__ == "__main__":
    main()
