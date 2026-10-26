#!/usr/bin/env python3
"""Filter lists added in Settings › Privacy (FilterLists.swift), checked in a
hidden probe.

Build first (`./build.sh`), then `python3 Tests/filter_lists.py`. It uses
split_view.py's harness in a world of its own (bld-flist-<checkout>): started
hidden, driven through ./bench's socket, everything removed afterwards.

A local server hands out the list, a page and the ad it loads, so what the
blocker stopped is counted where it would have arrived:

- a list added by address is fetched, converted and compiled, named from its
  `! Title:`, with what it skipped counted by why;
- its network filter keeps the ad from being requested at all, its element
  hiding hides, and a `#@#` exception lifts a hide on its site;
- switched off, the ad loads again; switched back on, it doesn't;
- updated, a filter added to the list blocks too;
- after a relaunch it is back from WebKit's store, blocking, without
  being fetched again;
- a list near WebKit's 150,000-rule limit says so; removed, it's gone;
- Find a setting finds it.
"""
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bld-flist")

LIST = """[Adblock Plus 2.0]
! Title: Probe list
! Expires: 2 days
/ads/banner.png
##.ad-box
##.kept-box
127.0.0.1#@#.kept-box
||pop.example^$popup
site.example##+js(set-constant, ads, false)
"""
EXTRA = "/ads/second.png\n"
BIG = "! Title: Big list\n" + "\n".join(f"||a{i}.example^" for i in range(140_000)) + "\n"

served = {"list": LIST}
hits = {}
lock = threading.Lock()


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        with lock:
            hits[self.path] = hits.get(self.path, 0) + 1
        kind = "text/plain"
        if self.path == "/list.txt":
            body = served["list"].encode()
        elif self.path == "/big.txt":
            body = BIG.encode()
        elif self.path.startswith("/page"):
            kind = "text/html"
            body = (b"<!doctype html><title>page</title>"
                    b"<img id=banner src='/ads/banner.png'><img id=second src='/ads/second.png'>"
                    b"<div class=ad-box>ad</div><div class=kept-box>kept</div><p class=story>story</p>")
        elif self.path.startswith("/ads/"):
            kind = "image/gif"
            body = bytes.fromhex("47494638396101000100800000000000ffffff21f90401000000002c00000000010001000002024401003b")
        else:
            self.send_response(404); self.end_headers(); return
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a): pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"


def fl(action="state", **f): return sv.cmd({"do": "filterlists", "action": action, **f})


def settled(origin, within=60, want=None):
    """The list once it's fetched, converted and compiled (or refused)."""
    end = time.time() + within
    while time.time() < end:
        st = fl()
        mine = [x for x in st["lists"] if x["origin"] == origin]
        if mine and not mine[0]["working"] and mine[0]["rules"] >= 0 and (want is None or want(mine[0])):
            return mine[0], st
        time.sleep(0.25)
    raise RuntimeError(f"{origin} never settled: {fl()}")


def count(path):
    with lock:
        return hits.get(path, 0)


def load(tab=None):
    """The page, freshly loaded; its tab id."""
    url = f"{BASE}/page?{time.time()}"
    if tab is None:
        tab = sv.cmd({"do": "open", "url": url})["id"]
    else:
        sv.cmd({"do": "go", "id": tab, "url": url})
    sv.cmd({"do": "wait", "id": tab, "seconds": 15})
    time.sleep(0.8)
    return tab


def shown(tab, selector):
    return sv.ev(tab, f"getComputedStyle(document.querySelector('{selector}')).display")


def main():
    t = sv.T()
    sv.setup()
    sv.launch()
    try:
        origin = f"{BASE}/list.txt"
        try:
            fl("add", origin="ftp://nope.example/list.txt"); t.ok("ftp refused", False)
        except RuntimeError as e:
            t.ok("an ftp address is refused, with why", "https" in str(e), str(e))

        started = time.time()
        fl("add", origin=origin)
        try:
            fl("add", origin=origin); t.ok("added twice refused", False)
        except RuntimeError as e:
            t.ok("the same list twice is refused", "Already" in str(e), str(e))
        mine, st = settled(origin)
        took = time.time() - started
        t.ok("fetched once", count("/list.txt") == 1, str(count("/list.txt")))
        t.ok("named from its title", mine["name"] == "Probe list", mine["name"])
        t.ok("no trouble", mine["trouble"] == "", mine["trouble"])
        t.ok("its filters used", mine["used"] == 4, str(mine))
        t.ok("what WebKit can't do, counted by why", mine["dropped"] == {"$popup": 1, "scriptlet": 1}, str(mine["dropped"]))
        t.ok("the blocker carries it", st["blocking"] == 1, str(st["blocking"]))
        print(f"  ..  added and compiled in {took:.2f}s")

        tab = load()
        t.ok("the ad is never requested", count("/ads/banner.png") == 0, str(hits))
        t.ok("a request the list doesn't name still goes", count("/ads/second.png") == 1, str(hits))
        t.ok("element hiding hides", shown(tab, ".ad-box") == "none")
        t.ok("a #@# exception lifts a hide on its site", shown(tab, ".kept-box") != "none", shown(tab, ".kept-box"))
        t.ok("the page itself is untouched", shown(tab, ".story") != "none")

        fl("turn", id=mine["id"], on=False)
        t.ok("switched off, the blocker drops it", fl()["blocking"] == 0)
        load(tab)
        t.ok("switched off, the ad loads", count("/ads/banner.png") == 1, str(hits))
        t.ok("switched off, nothing is hidden", shown(tab, ".ad-box") != "none")
        fl("turn", id=mine["id"], on=True)
        before = count("/ads/banner.png")
        load(tab)
        t.ok("back on, the ad is stopped again", count("/ads/banner.png") == before, str(hits))

        served["list"] = LIST + EXTRA
        fetched = mine["fetched"]
        fl("refresh", id=mine["id"])
        mine, st = settled(origin, want=lambda x: x["fetched"] > fetched)
        t.ok("updated, it has the new filter", mine["used"] == 5, str(mine))
        second = count("/ads/second.png")
        load(tab)
        t.ok("updated, the new filter blocks", count("/ads/second.png") == second, str(hits))
        t.ok("still one list on the blocker", st["blocking"] == 1, str(st["blocking"]))

        found = sv.cmd({"do": "settings", "find": "easylist"})["found"]
        t.ok("Find a setting finds it", any("shield.lists" in str(f) for f in found), str(found)[:300])

        # Back after a relaunch, from WebKit's store, without the network.
        fetches = count("/list.txt")
        sv.quit()
        time.sleep(1)
        sv.launch()
        mine, st = settled(origin, within=10)
        t.ok("back after a relaunch", st["blocking"] == 1 and mine["used"] == 5, str(st))
        t.ok("not fetched again: it isn't due", count("/list.txt") == fetches, str(count("/list.txt")))
        before = count("/ads/banner.png")
        load()
        t.ok("after a relaunch, the ad is still stopped", count("/ads/banner.png") == before, str(hits))

        big = f"{BASE}/big.txt"
        started = time.time()
        fl("add", origin=big)
        mine_big, st = settled(big, within=120)
        print(f"  ..  140,000-filter list added and compiled in {time.time() - started:.2f}s")
        t.ok("a big list is near the limit, and says so", mine_big["nearLimit"] and mine_big["rules"] >= 135_000, str(mine_big)[:200])
        t.ok("and still blocks", st["blocking"] == 2 and mine_big["trouble"] == "", str(st)[:300])

        fl("remove", id=mine_big["id"])
        fl("remove", id=mine["id"])
        st = fl()
        t.ok("removed, both are gone", st["lists"] == [] and st["blocking"] == 0, str(st))
        before = count("/ads/banner.png")
        load()
        t.ok("removed, the ad loads", count("/ads/banner.png") == before + 1, str(hits))
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
