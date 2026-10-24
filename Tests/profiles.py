#!/usr/bin/env python3
"""Profiles (Profiles.swift), checked in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/profiles.py` from a
worktree. It uses split_view.py's harness: started hidden, in a world of its
own, driven through ./bench's socket, everything removed afterwards. The
windows a profile needs are made while the app is hidden (as
closed_windows.py makes its own); `pages on` is never used, and every window
is checked to be off screen after each one is made — the run stops if one
isn't.

Checked here:
- a space from before profiles, with sign-ins of its own, is in Personal and
  keeps its cookies through a relaunch;
- a second profile's window shows only that profile's spaces, and Personal's
  window none of the second profile's;
- two spaces of the second profile share its cookies; Personal's spaces
  don't see them, nor it theirs;
- a tab opened from a tab (window.open, a link opened in a new tab) keeps
  the profile, and so does a new window opened from that window;
- history, and what the address field offers from it, is each profile's;
- a relaunch brings each window back in its profile, with its tabs;
- deleting a profile closes its windows and erases its cookies, spaces and
  history, and a profile made again with the same name starts signed out;
- Arc's profiles come in as Search profiles, each with its spaces.
"""
import json
import os
import sys
import threading
import time
import uuid
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bld-prof")
seen = {}  # path with query -> the Cookie header the site was sent


class Site(BaseHTTPRequestHandler):
    def do_GET(self):
        seen[self.path] = self.headers.get("Cookie") or ""
        headers = [("Content-Type", "text/html")]
        path = self.path.split("?")[0]
        if path == "/set":
            who = self.path.split("v=", 1)[1]
            headers.append(("Set-Cookie", f"who={who}; Path=/; Max-Age=3600"))
            body = f"<!doctype html><title>set {who}</title>"
        elif path == "/opener":
            body = ("<!doctype html><title>opener</title>"
                    "<button id=go onclick=\"window.open('/echo?popup')\">open</button>"
                    "<a id=blank target=_blank href='/echo?blank'>blank</a>")
        else:
            body = f"<!doctype html><title>{self.path.strip('/')}</title><p>{self.path}"
        data = body.encode()
        self.send_response(200)
        for k, v in headers: self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers(); self.wfile.write(data)

    def log_message(self, *a): pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), Site)
threading.Thread(target=srv.serve_forever, daemon=True).start()
SITE = f"http://127.0.0.1:{srv.server_port}"
LEGACY = str(uuid.uuid4()).upper()


def c(req, window=None):
    if window: req = {**req, "window": window}
    return sv.cmd(req)


def windows():
    return c({"do": "windows"})["windows"]


def off_screen(t, label):
    """Every window off screen, or the run stops here."""
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


def profile(action="list", window=None, **f):
    return c({"do": "profile", "action": action, **f}, window)


def space(action, window=None, **f):
    return c({"do": "space", "action": action, **f}, window)


def arc_fixture():
    """Arc as this world will find it: a space in its first profile, and one
    in a second profile Arc calls "Raycast"."""
    root = f"{sv.SUPPORT}/Import/Arc"
    for folder in ["Default", "Profile 1"]:
        os.makedirs(f"{root}/User Data/{folder}", exist_ok=True)
        Path(f"{root}/User Data/{folder}/History").write_bytes(b"")
    Path(f"{root}/User Data/Local State").write_text(json.dumps(
        {"profile": {"info_cache": {"Default": {"name": "Me"}, "Profile 1": {"name": "Arc Raycast"}}}}))
    items = [{"id": "boxA", "childrenIds": ["a0"]}, {"id": "boxB", "childrenIds": ["b0"]},
             {"id": "a0", "title": "A", "data": {"tab": {"savedURL": f"{SITE}/arc-default", "savedTitle": "A"}}},
             {"id": "b0", "title": "B", "data": {"tab": {"savedURL": f"{SITE}/arc-raycast", "savedTitle": "B"}}}]
    sidebar = {"sidebar": {"containers": [{
        "spaces": [{"title": "Arc Home", "profile": {"default": {}}, "containerIDs": ["pinned", "boxA"]},
                   {"title": "Arc Work", "profile": {"custom": {"_0": {"directoryBasename": "Profile 1"}}},
                    "containerIDs": ["pinned", "boxB"]}],
        "items": items,
    }]}}
    Path(f"{root}/StorableSidebar.json").write_text(json.dumps(sidebar))


def main():
    t = sv.T()
    try:
        sv.setup(spaces=True, **{"panel.sites": True})
        # A space from before profiles, signed in on its own.
        os.makedirs(sv.SUPPORT, exist_ok=True)
        Path(f"{sv.SUPPORT}/spaces.json").write_text(json.dumps([
            {"id": sv.FIRST_SPACE.upper(), "name": "Personal", "colour": 0},
            {"id": LEGACY, "name": "Legacy", "colour": 0, "sharesSignIns": False}]))
        sv.launch()

        print("— a space from before profiles")
        p = profile()
        t.ok("one profile, Personal, and no badge", [x["name"] for x in p["profiles"]] == ["Personal"] and not p["badge"], p)
        t.ok("Legacy is one of Personal's spaces", p["profiles"][0]["spaces"] == ["Personal", "Legacy"], p)
        open_tab(f"{SITE}/set?v=personal")
        space("go", index=2)
        open_tab(f"{SITE}/set?v=legacy")
        open_tab(f"{SITE}/echo?legacy1")
        t.ok("Legacy has its own cookies", cookie_sent("/echo?legacy1") == "who=legacy", seen.get("/echo?legacy1"))
        space("go", index=1)
        open_tab(f"{SITE}/echo?personal1")
        t.ok("Personal's first space has its own", cookie_sent("/echo?personal1") == "who=personal", seen.get("/echo?personal1"))

        print("— a second profile")
        made = profile("new", name="Raycast")
        p = profile()
        rc = next(x for x in p["profiles"] if x["name"] == "Raycast")
        t.ok("Raycast made, with one space of its own", rc["spaces"] == ["Raycast"] and rc["home"] == made["home"], p)
        t.ok("Personal's window shows none of Raycast's spaces", p["spaces"] == ["Personal", "Legacy"], p["spaces"])
        t.ok("the badge shows now", p["badge"], p)
        t.ok("Raycast's store is its own", rc["store"].lower() == made["id"].lower(), rc)
        profile("window", name="Raycast")
        time.sleep(1.5)
        off_screen(t, "Raycast's window")
        ws = windows()
        t.ok("a second window, in Raycast", len(ws) == 2 and ws[1]["profile"] == "Raycast" and ws[0]["profile"] == "Personal", ws)
        t.ok("Raycast's window shows only Raycast's spaces", ws[1]["spaces"] == ["Raycast"], ws[1])

        open_tab(f"{SITE}/set?v=raycast", window=2)
        open_tab(f"{SITE}/echo?rc1", window=2)
        t.ok("Raycast is sent its own cookie, not Personal's", cookie_sent("/echo?rc1") == "who=raycast", seen.get("/echo?rc1"))
        open_tab(f"{SITE}/echo?personal2")
        t.ok("Personal is still sent Personal's", cookie_sent("/echo?personal2") == "who=personal", seen.get("/echo?personal2"))

        # A website in the side panel is signed in as its window's profile.
        c({"do": "sidepanel", "action": "site", "url": f"{SITE}/echo?panel-rc"}, 2)
        t.ok("the side panel's site in Raycast's window is signed in as Raycast", cookie_sent("/echo?panel-rc") == "who=raycast", seen.get("/echo?panel-rc"))
        st = c({"do": "sidepanel"}, 2)
        t.ok("and uses a Raycast store", st.get("content", {}).get("profileStore") is True, st.get("content"))
        c({"do": "sidepanel", "action": "close"}, 2)
        c({"do": "sidepanel", "action": "site", "url": f"{SITE}/echo?panel-personal"})
        t.ok("Personal's window's side panel is signed in as Personal", cookie_sent("/echo?panel-personal") == "who=personal", seen.get("/echo?panel-personal"))
        c({"do": "sidepanel", "action": "close"})

        space("new", window=2, name="Raycast Two")
        time.sleep(0.8)
        p2 = profile(window=2)
        t.ok("Raycast's second space is Raycast's", p2["spaces"] == ["Raycast", "Raycast Two"] and p2["window"] == "Raycast", p2)
        t.ok("and Personal's window still doesn't see it", profile()["spaces"] == ["Personal", "Legacy"])
        open_tab(f"{SITE}/echo?rc2", window=2)
        t.ok("two spaces of one profile share its cookies", cookie_sent("/echo?rc2") == "who=raycast", seen.get("/echo?rc2"))
        space("new", name="Personal Two")
        time.sleep(0.8)
        open_tab(f"{SITE}/echo?personal3")
        t.ok("a Personal space signed in with Personal never sees Raycast's", cookie_sent("/echo?personal3") == "who=personal", seen.get("/echo?personal3"))

        print("— what is opened from a Raycast tab")
        opener = open_tab(f"{SITE}/opener", window=2)
        c({"do": "tap", "id": opener, "selector": "#go"}, 2)
        t.ok("a page's window.open on a click keeps the profile", cookie_sent("/echo?popup") == "who=raycast", seen.get("/echo?popup"))
        # A fresh one: the first is behind the page it opened.
        opener2 = open_tab(f"{SITE}/opener?again", window=2)
        c({"do": "tap", "id": opener2, "selector": "#blank"}, 2)
        t.ok("a target=_blank link keeps it", cookie_sent("/echo?blank") == "who=raycast", seen.get("/echo?blank"))
        c({"do": "split", "action": "open", "url": f"{SITE}/echo?link", "from": opener, "foreground": False}, 2)
        t.ok("a link opened in a new tab keeps it", cookie_sent("/echo?link") == "who=raycast", seen.get("/echo?link"))
        ws = windows()
        rc_store = rc["store"].lower()
        t.ok("every tab of Raycast's window uses a Raycast store", all(s.lower() == rc_store for s in ws[1]["stores"]), ws[1]["stores"])
        t.ok("no tab of Personal's window does", not any(s.lower() == rc_store for s in ws[0]["stores"]), ws[0]["stores"])
        c({"do": "windows", "action": "front", "n": 2})
        c({"do": "windows", "action": "new"})
        time.sleep(1.2)
        off_screen(t, "a new window from Raycast's")
        ws = windows()
        t.ok("a new window from Raycast's is Raycast's", len(ws) == 3 and ws[2]["profile"] == "Raycast", [w["profile"] for w in ws])
        open_tab(f"{SITE}/echo?w3", window=3)
        t.ok("and is signed in as Raycast", cookie_sent("/echo?w3") == "who=raycast", seen.get("/echo?w3"))
        c({"do": "windows", "action": "close", "n": 3})
        c({"do": "windows", "action": "front", "n": 1})
        time.sleep(0.6)

        print("— history")
        open_tab(f"{SITE}/only-personal-page")
        open_tab(f"{SITE}/only-raycast-page", window=2)
        time.sleep(2.2)
        typed = f"127.0.0.1:{srv.server_port}/only"
        hp = profile("history", typed=typed)
        hr = profile("history", window=2, typed=typed)
        has = lambda h, s: any(s in u for u in h["history"])
        offers = lambda h, s: any(s in u for u in h["offers"])
        t.ok("Personal's history has its page, not Raycast's", has(hp, "only-personal") and not has(hp, "only-raycast"), hp["history"][:6])
        t.ok("Raycast's has its page, not Personal's", has(hr, "only-raycast") and not has(hr, "only-personal"), hr["history"][:6])
        t.ok("the field offers each profile only its own", offers(hp, "only-personal") and not offers(hp, "only-raycast")
             and offers(hr, "only-raycast") and not offers(hr, "only-personal"), (hp["offers"], hr["offers"]))
        t.ok("Raycast's history has a file of its own", os.path.exists(f"{sv.SUPPORT}/history-{made['id']}.json"))

        print("— a relaunch")
        sv.quit(); time.sleep(1); seen.clear()
        sv.launch()
        off_screen(t, "relaunch")
        ws = windows()
        t.ok("both windows back, each in its profile", [w["profile"] for w in ws] == ["Personal", "Raycast"], [(w["profile"], w["space"]) for w in ws])
        t.ok("Raycast's window has its tabs back", any("only-raycast-page" in u for u in (ws[1]["tabs"] if len(ws) > 1 else [])), ws[1:] and ws[1]["tabs"])
        open_tab(f"{SITE}/echo?rc3", window=2)
        t.ok("Raycast still signed in as Raycast", cookie_sent("/echo?rc3") == "who=raycast", seen.get("/echo?rc3"))
        space("go", index=2)
        open_tab(f"{SITE}/echo?legacy2")
        t.ok("Legacy's own cookies came through the relaunch", cookie_sent("/echo?legacy2") == "who=legacy", seen.get("/echo?legacy2"))
        space("go", index=1)

        print("— the last Raycast window closed, then opened again")
        c({"do": "windows", "action": "close", "n": 2})
        time.sleep(1)
        profile("window", name="Raycast")
        time.sleep(1.5)
        off_screen(t, "Raycast's window again")
        ws = windows()
        t.ok("Raycast's window comes back with its tabs", len(ws) == 2 and any("only-raycast-page" in u for u in ws[1]["tabs"]), ws)

        print("— deleting a profile")
        profile("delete", name="Raycast")
        time.sleep(3.5)
        p = profile()
        ws = windows()
        t.ok("Raycast is gone, and its window", [x["name"] for x in p["profiles"]] == ["Personal"] and [w["profile"] for w in ws] == ["Personal"], (p["profiles"], ws))
        t.ok("its spaces are gone from the list", not any(s["profile"] for s in json.load(open(f"{sv.SUPPORT}/spaces.json")) if s.get("profile")), p)
        t.ok("its history file is gone", not os.path.exists(f"{sv.SUPPORT}/history-{made['id']}.json"))
        again = profile("new", name="Raycast")
        profile("window", name="Raycast")
        time.sleep(1.5)
        off_screen(t, "the new Raycast's window")
        t.ok("a profile made again has a new id", again["id"] != made["id"])
        open_tab(f"{SITE}/echo?rc4", window=2)
        t.ok("and starts signed out", cookie_sent("/echo?rc4") == "", seen.get("/echo?rc4"))
        hr = profile("history", window=2, typed=typed)
        t.ok("with no history", not has(hr, "only-raycast") and not has(hr, "only-personal"), hr["history"][:5])
        open_tab(f"{SITE}/echo?personal4")
        t.ok("Personal still signed in", cookie_sent("/echo?personal4") == "who=personal", seen.get("/echo?personal4"))
        # What WebKit still holds under the deleted profile's id: nothing,
        # once the sweep has run.
        out = space("list", records=True)
        t.ok("the deleted profile's store was removed or is being removed",
             made["id"].upper() not in [s.upper() for s in out.get("stores", [])] or made["id"].upper() in [e.upper() for e in p["erasing"]],
             (out.get("stores"), p["erasing"]))
    except Exception as error:
        t.ok("profiles ran to the end", False, repr(error))
    finally:
        sv.finish()

    print("— Arc's profiles")
    try:
        sv.setup()
        arc_fixture()
        sv.launch()
        out = sv.cmd({"do": "import", "from": "Arc", "what": ["spaces"], "profile": "all"})
        time.sleep(1)
        p = profile()
        names = {x["name"]: x["spaces"] for x in p["profiles"]}
        t.ok("Arc's second profile is a Search profile, named as Arc names it", "Arc Raycast" in names, names)
        t.ok("with its space in it", names.get("Arc Raycast") == ["Arc Work"], names)
        t.ok("Arc's first profile's space is Personal's", "Arc Home" in names.get("Personal", []) and "Arc Work" not in names.get("Personal", []), names)
        t.ok("this window shows Personal's only", "Arc Work" not in p["spaces"], p["spaces"])
        rc = next((x for x in p["profiles"] if x["name"] == "Arc Raycast"), None)
        spaces_file = json.load(open(f"{sv.SUPPORT}/spaces.json"))
        work = next((s for s in spaces_file if s["name"] == "Arc Work"), {})
        session = json.load(open(f"{sv.SUPPORT}/session-{work.get('id', 'x')}.json")) if work else {"tabs": []}
        t.ok("its pinned page waits in its own session file", [x["url"] for x in session["tabs"]] == [f"{SITE}/arc-raycast"], session)
        t.ok("signed in with the profile's own cookies", work.get("sharesSignIns") is True and rc and work.get("profile", "").lower() == rc["id"].lower(), work)
        t.ok("the import counted both spaces", (out.get("arc") or {}).get("spaces") == 2, out)
    except Exception as error:
        t.ok("Arc's profiles ran to the end", False, repr(error))
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
