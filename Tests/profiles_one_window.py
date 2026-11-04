#!/usr/bin/env python3
"""Profiles in one window (OneWindow.swift, idea 419), checked in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/profiles_one_window.py`
from a worktree. It uses split_view.py's harness: started hidden, in a world
of its own, driven through ./bench's socket, everything removed afterwards.
Nothing is ever ordered onto a screen: a hidden probe's windows are only
ordered out, never in, so what is "on screen" here is the model's word for
it (`tucked`), and every window is checked to be off screen after each step.

Checked here, with Settings › Profiles in one window on:
- the space's menu lists every profile's spaces under the profile's name,
  ⌃1–⌃9 counting through them all;
- ⌃2 (a space of another profile) brings that profile's window into the
  first one's place — same frame, the column folded as it was — and tucks
  the first out of the Window menu; its sign-ins stay its own;
- back from the menu: the first window again, its page never reloaded;
- a swipe past the last space goes on to the next profile, and back;
- the profile badge's choice does the same;
- a relaunch brings the merged window back as one, the profile you were in
  in front;
- closing it with another window open closes the tucked one with it, and
  ⇧⌘T brings both back, merged;
- closing it as the last window keeps it whole; ⌘N brings it back;
- a profile deleted while its window is in front: another takes its place;
- turned off, the tucked window comes out as a window of its own.
"""
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bld-onewin")
seen = {}  # path -> the Cookie header it was last sent
hits = {}  # path -> how many times it was asked for


class Site(BaseHTTPRequestHandler):
    def do_GET(self):
        seen[self.path] = self.headers.get("Cookie") or ""
        hits[self.path] = hits.get(self.path, 0) + 1
        headers = [("Content-Type", "text/html")]
        if self.path.startswith("/set"):
            who = self.path.split("v=", 1)[1]
            headers.append(("Set-Cookie", f"who={who}; Path=/; Max-Age=3600"))
        body = f"<!doctype html><title>{self.path.strip('/')}</title><p>{self.path}".encode()
        self.send_response(200)
        for k, v in headers: self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)

    def log_message(self, *a): pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), Site)
threading.Thread(target=srv.serve_forever, daemon=True).start()
SITE = f"http://127.0.0.1:{srv.server_port}"


def c(req, window=None):
    if window: req = {**req, "window": window}
    return sv.cmd(req)


def windows():
    return c({"do": "windows"})["windows"]


def off_screen(t, label):
    shown = [w for w in windows() if w["shown"]]
    t.ok(f"no window on screen ({label})", not shown, shown)
    if shown:
        sv.quit()
        sys.exit("a window reached the screen: stopped")


def open_tab(url, window=None, wait=1.0):
    r = c({"do": "split", "action": "open", "url": url}, window)["resultID"]
    time.sleep(wait)
    return r


def cookie_sent(path, within=6):
    until = time.time() + within
    while path not in seen and time.time() < until: time.sleep(0.1)
    return seen.get(path)


def space(action, window=None, **f):
    return c({"do": "space", "action": action, **f}, window)


def visible(ws):
    return [w for w in ws if not w["tucked"]]


def by_profile(ws, name):
    return next((w for w in ws if w["profile"] == name), None)


def main():
    t = sv.T()
    try:
        sv.setup(spaces=True, **{"profiles.oneWindow": True})
        sv.launch()
        made = c({"do": "profile", "action": "new", "name": "Raycast"})
        time.sleep(0.8)

        print("— the space's menu")
        s = space("list")
        menu = [(m["title"], m["key"], m["header"]) for m in s["menu"]]
        t.ok("every profile's spaces, under each profile's name",
             menu[:4] == [("Personal", "", True), ("Personal", "1", False), ("Raycast", "", True), ("Raycast", "2", False)], menu[:6])
        t.ok("⌃ keys count through them all", s["every"] == ["Personal", "Raycast"], s["every"])

        print("— a space of another profile")
        open_tab(f"{SITE}/set?v=personal")
        open_tab(f"{SITE}/keep-personal")
        t.ok("Personal's page loaded once", hits.get("/keep-personal") == 1, hits)
        c({"do": "windows", "action": "frame", "n": 1, "frame": [120, 140, 1000, 700]})
        c({"do": "ui", "folded": True})
        time.sleep(0.4)
        space("go", index=2)  # ⌃2
        time.sleep(1.5)
        off_screen(t, "Raycast's window made")
        ws = windows()
        p, r = by_profile(ws, "Personal"), by_profile(ws, "Raycast")
        t.ok("two windows, one merged window", len(ws) == 2 and p and r and p["merge"] and p["merge"] == r["merge"], ws)
        t.ok("Raycast's in front, Personal's tucked", r and not r["tucked"] and r["front"] and p["tucked"], [(w["profile"], w["tucked"], w["front"]) for w in ws])
        t.ok("Raycast's in the Window menu, Personal's not", r and r["inWindowMenu"] and not p["inWindowMenu"], ws)
        t.ok("in Personal's exact place", r and r["frame"] == p["frame"], (p and p["frame"], r and r["frame"]))
        t.ok("the column folded as Personal's was", r and r["folded"] is True, r and r["folded"])
        t.ok("at the space chosen", r and r["space"] == "Raycast", r and r["space"])
        open_tab(f"{SITE}/set?v=raycast", window=2)
        open_tab(f"{SITE}/echo?rc1", window=2)
        t.ok("Raycast's pages are sent Raycast's cookie", cookie_sent("/echo?rc1") == "who=raycast", seen.get("/echo?rc1"))
        rc_store = made["id"].lower()
        t.ok("every tab of Raycast's window uses Raycast's store", all(x.lower() == rc_store for x in by_profile(windows(), "Raycast")["stores"]))
        t.ok("no tab of Personal's does", not any(x.lower() == rc_store for x in by_profile(windows(), "Personal")["stores"]))

        print("— back from the menu")
        space("menu", window=2, title="Personal")
        time.sleep(1)
        off_screen(t, "back to Personal")
        ws = windows()
        p, r = by_profile(ws, "Personal"), by_profile(ws, "Raycast")
        t.ok("still two windows", len(ws) == 2, ws)
        t.ok("Personal's in front, Raycast's tucked", not p["tucked"] and p["front"] and r["tucked"] and not r["inWindowMenu"], ws)
        t.ok("Personal's page never reloaded", hits.get("/keep-personal") == 1, hits.get("/keep-personal"))
        open_tab(f"{SITE}/echo?p1")
        t.ok("Personal still sent Personal's cookie", cookie_sent("/echo?p1") == "who=personal", seen.get("/echo?p1"))

        print("— swipes")
        c({"do": "ui", "folded": False})
        time.sleep(0.3)
        space("swipe", window=1, dx=-120)
        time.sleep(1.2)
        ws = windows()
        t.ok("past Personal's last space: Raycast's window", by_profile(ws, "Raycast")["front"] and not by_profile(ws, "Raycast")["tucked"]
             and by_profile(ws, "Personal")["tucked"], [(w["profile"], w["tucked"]) for w in ws])
        rs = space("list", window=2)
        t.ok("and no card for a new space on the way", not rs["making"], rs["making"])
        space("swipe", window=2, dx=120)
        time.sleep(1.2)
        ws = windows()
        t.ok("back before Raycast's first: Personal's", by_profile(ws, "Personal")["front"] and by_profile(ws, "Raycast")["tucked"], [(w["profile"], w["tucked"]) for w in ws])
        t.ok("still only two windows", len(ws) == 2, len(ws))
        off_screen(t, "swipes")

        print("— the profile badge")
        c({"do": "profile", "action": "window", "name": "Raycast"})
        time.sleep(1)
        ws = windows()
        t.ok("choosing Raycast swaps in place", len(ws) == 2 and not by_profile(ws, "Raycast")["tucked"] and by_profile(ws, "Personal")["tucked"], ws)

        print("— a relaunch")
        sv.quit(); time.sleep(1)
        sv.launch()
        time.sleep(1)
        off_screen(t, "relaunch")
        ws = windows()
        t.ok("both back, merged", len(ws) == 2 and ws[0]["merge"] and ws[0]["merge"] == ws[1]["merge"], [(w["profile"], w["merge"], w["tucked"]) for w in ws])
        t.ok("one on screen: Raycast's, as it was left", [w["profile"] for w in visible(ws)] == ["Raycast"], [(w["profile"], w["tucked"]) for w in ws])
        t.ok("Personal's tucked, out of the Window menu", by_profile(ws, "Personal")["tucked"] and not by_profile(ws, "Personal")["inWindowMenu"], ws)
        t.ok("each with its tabs", any("keep-personal" in u for u in by_profile(ws, "Personal")["tabs"])
             and any("echo?rc1" in u for u in by_profile(ws, "Raycast")["tabs"]), [(w["profile"], w["tabs"]) for w in ws])

        print("— closed with another window open")
        c({"do": "windows", "action": "new"})
        time.sleep(1.2)
        off_screen(t, "another window")
        ws = windows()
        t.ok("a third window, on its own", len(ws) == 3 and not ws[2]["merge"] and not ws[2]["tucked"], [(w["profile"], w["merge"]) for w in ws])
        n = next(w["n"] for w in ws if w["profile"] == "Raycast" and w["merge"])
        c({"do": "windows", "action": "close", "n": n})
        time.sleep(1.2)
        ws = windows()
        t.ok("the merged window closed whole", len(ws) == 1 and not ws[0]["merge"], [(w["profile"], w["merge"]) for w in ws])
        c({"do": "windows", "action": "reopen"})
        time.sleep(1.5)
        off_screen(t, "⇧⌘T")
        ws = windows()
        merged = [w for w in ws if w["merge"]]
        t.ok("⇧⌘T brings both back, merged", len(merged) == 2 and len({w["merge"] for w in merged}) == 1, [(w["profile"], w["merge"], w["tucked"]) for w in ws])
        t.ok("Raycast's in front of it again", [w["profile"] for w in merged if not w["tucked"]] == ["Raycast"], [(w["profile"], w["tucked"]) for w in merged])
        t.ok("with their tabs", any("keep-personal" in u for u in next((w["tabs"] for w in merged if w["profile"] == "Personal"), [])), merged)

        print("— the last window closed, then ⌘N")
        ws = windows()
        c({"do": "windows", "action": "close", "n": next(w["n"] for w in ws if not w["merge"])})
        time.sleep(1)
        ws = windows()
        n = next(w["n"] for w in ws if w["profile"] == "Raycast")
        c({"do": "windows", "action": "close", "n": n})
        time.sleep(1)
        ws = windows()
        t.ok("kept whole: both still there", len(ws) == 2 and by_profile(ws, "Raycast")["shut"] and by_profile(ws, "Personal")["tucked"], [(w["profile"], w["shut"], w["tucked"]) for w in ws])
        c({"do": "windows", "action": "new"})
        time.sleep(1)
        off_screen(t, "⌘N")
        ws = windows()
        t.ok("⌘N brings it back as it was", len(ws) == 2 and not by_profile(ws, "Raycast")["shut"] and by_profile(ws, "Personal")["tucked"], [(w["profile"], w["shut"], w["tucked"]) for w in ws])

        print("— a profile deleted while its window is in front")
        c({"do": "profile", "action": "new", "name": "Third"})
        time.sleep(0.8)
        c({"do": "profile", "action": "window", "name": "Third"})
        time.sleep(1)
        ws = windows()
        t.ok("Third's window in front of the merged window", len(ws) == 3 and [w["profile"] for w in visible(ws)] == ["Third"], [(w["profile"], w["tucked"]) for w in ws])
        c({"do": "profile", "action": "delete", "name": "Third"})
        time.sleep(1.5)
        off_screen(t, "Third deleted")
        ws = windows()
        t.ok("another of the merged window takes its place", len(ws) == 2 and len(visible(ws)) == 1 and visible(ws)[0]["profile"] != "Third", [(w["profile"], w["tucked"]) for w in ws])

        print("— turned off")
        c({"do": "settings", "set": "profiles.oneWindow", "value": False})
        time.sleep(0.8)
        off_screen(t, "turned off")
        ws = windows()
        t.ok("nothing tucked, nothing merged", all(not w["tucked"] and not w["merge"] and w["inWindowMenu"] for w in ws), [(w["profile"], w["tucked"], w["merge"]) for w in ws])
        s = space("list")
        t.ok("the menu lists this window's profile's spaces only", not any(m["header"] for m in s["menu"]) and s["every"] == [s["current"]], s["every"])
    except Exception as error:
        t.ok("profiles in one window ran to the end", False, repr(error))
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
