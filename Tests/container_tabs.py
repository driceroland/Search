#!/usr/bin/env python3
"""Container tabs (Containers.swift), checked end to end in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/container_tabs.py`. The app
starts hidden in a world of its own (see split_view.use), driven through
./bench's socket. A local server sets a cookie on /set?v=… and says on
/show which cookie it was sent. Three tabs on that one site, in one space:
one in no container, one in “Work”, one in “Uni”. Checked:

- a cookie set in one is absent from the other two, and each keeps its own;
- the three report three different stores, the containers' under their ids;
- a target=_blank link from the Work tab opens in Work, with Work's cookie;
- a pinned container tab stays a pin in its container;
- after ⌘Q and a relaunch every tab is in the container it was in, still
  signed in there, and pins.json and the session say so;
- moved to a space with sign-ins of its own, a container tab keeps its
  container and its cookie;
- deleting a container puts its tabs back in no container, with no
  container's cookie.

Nothing here makes, shows or brings forward a window.
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("container-tabs")


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)
        extra = []
        if url.path == "/set":
            who = parse_qs(url.query).get("v", [""])[0]
            # Kept across a quit: a sign-in that lasts.
            extra.append(("Set-Cookie", f"who={who}; Max-Age=86400; Path=/"))
            body = f"<title>set</title>set {who}"
        elif url.path == "/show":
            jar = self.headers.get("Cookie") or ""
            who = next((c.split("=", 1)[1] for c in jar.split("; ") if c.startswith("who=")), "none")
            body = f"<title>show</title>who={who}"
        elif url.path == "/link":
            body = ('<a id="go" target="_blank" href="/show?from=link" '
                    'style="display:block;font-size:60px;line-height:200px">link</a>')
        else:
            body = f"<title>{url.path}</title>{url.path}"
        data = ("<!doctype html><meta charset=utf-8>" + body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Cache-Control", "no-store")
        for k, v in extra:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


sv.srv.RequestHandlerClass = H


def box(**f): return sv.cmd({"do": "container", **f})
def tabs(): return sv.cmd({"do": "tabs"})["tabs"]
def tab(id): return next((x for x in tabs() if x["id"] == id), None)


def go(id, path):
    """The tab on screen at path, loaded."""
    sv.cmd({"do": "select", "id": id})
    sv.cmd({"do": "go", "id": id, "url": f"{sv.BASE}{path}"})
    sv.cmd({"do": "wait", "id": id, "seconds": 10})
    time.sleep(0.3)


def who(id):
    """Which cookie the site was sent in that tab."""
    go(id, "/show")
    text = sv.cmd({"do": "text", "id": id})["text"]
    return text.strip().removeprefix("who=")


def insert(name):
    """A tab of the row, named: the name stays through every page it goes to
    and every relaunch, where the id doesn't."""
    id = sv.sp("insert", url=f"{sv.BASE}/show", index=len(tabs()))["resultID"]
    sv.sp("name", id=id, name=name)
    return id


def named():
    return {x["name"]: x for x in tabs() if x["name"]}


def main():
    t = sv.T()
    try:
        sv.setup(**{"start.fresh": False, "spaces": True, "containers": True})
        sv.launch()
        sv.cmd({"do": "ui", "confirm": True})

        listed = box()["containers"]
        t.ok("no containers to begin with", listed == [], listed)
        work = box(action="new", name="Work")["id"]
        uni = box(action="new", name="Uni")["id"]
        names = {c["id"]: c["name"] for c in box()["containers"]}
        t.ok("two containers made", names == {work: "Work", uni: "Uni"}, names)

        plain = insert("plain")
        w = insert("work")
        u = insert("uni")
        time.sleep(1)
        box(action="set", id=w, container=work)
        box(action="set", id=u, container=uni)
        time.sleep(0.5)
        got = {k: tab(k)["container"] for k in (plain, w, u)}
        t.ok("each tab is in the container it was put in",
             got == {plain: "", w: work, u: uni}, got)
        stores = {k: tab(k)["store"] for k in (plain, w, u)}
        t.ok("three tabs, three different stores", len(set(stores.values())) == 3, stores)
        t.ok("a container's store is under the container's id",
             stores[w] == work and stores[u] == uni, stores)

        # The same site, the same space: a cookie in one is in no other.
        go(plain, "/set?v=plain")
        t.ok("the plain tab has its cookie", who(plain) == "plain")
        t.ok("Work doesn't have it", who(w) == "none", who(w))
        t.ok("Uni doesn't have it", who(u) == "none", who(u))
        go(w, "/set?v=work")
        go(u, "/set?v=uni")
        seen = {"plain": who(plain), "work": who(w), "uni": who(u)}
        t.ok("each tab keeps its own sign-in", seen == {"plain": "plain", "work": "work", "uni": "uni"}, seen)

        # A link opened in a new tab from a container tab is in that container.
        before = {x["id"] for x in tabs()}
        go(w, "/link")
        sv.cmd({"do": "tap", "id": w, "selector": "#go"})
        time.sleep(2)
        opened = [x for x in tabs() if x["id"] not in before]
        t.ok("the target=_blank link opened a tab", len(opened) == 1, [x["url"] for x in tabs()])
        if opened:
            t.ok("…in Work", opened[0]["container"] == work, opened[0])
            t.ok("…signed in as Work", who(opened[0]["id"]) == "work")
            sv.sp("name", id=opened[0]["id"], name="link")

        # A pin in a container.
        go(u, "/show?pin=uni")
        pinned = sv.cmd({"do": "pin", "id": u})
        t.ok("the Uni tab pinned", pinned["pin"] != "", pinned)
        t.ok("…and still in Uni", tab(u)["container"] == uni, tab(u))
        sv.sp("save")
        pins = json.load(open(f"{sv.SUPPORT}/pins.json"))
        kept = [p for defs in pins.values() for p in defs if "pin=uni" in p["home"]]
        t.ok("pins.json keeps the pin's container", [p.get("container") for p in kept] == [uni], pins)

        # Quit and come back.
        sv.quit()
        time.sleep(1)
        session = json.load(open(f"{sv.SUPPORT}/session.json"))
        saved = {e.get("name"): e.get("container") for e in session["tabs"]}
        t.ok("the session keeps each tab's container",
             saved.get("plain", "missing") is None and saved.get("work") == work
             and saved.get("link") == work and saved.get("uni") == uni, saved)
        sv.launch()
        time.sleep(1)
        after = named()
        t.ok("after a relaunch the plain tab is in none",
             after.get("plain", {}).get("container") == "", list(after))
        t.ok("…the Work tab in Work", after.get("work", {}).get("container") == work)
        t.ok("…the link's tab in Work", after.get("link", {}).get("container") == work)
        t.ok("…the Uni pin in Uni, still a pin",
             after.get("uni", {}).get("container") == uni and "pin=uni" in after.get("uni", {}).get("url", ""),
             after.get("uni"))
        if all(k in after for k in ("plain", "work", "uni")):
            plain, w, u = after["plain"]["id"], after["work"]["id"], after["uni"]["id"]
            seen = {"plain": who(plain), "work": who(w), "uni": who(u)}
            t.ok("…and each still signed in as before", seen == {"plain": "plain", "work": "work", "uni": "uni"}, seen)

            # To a space signed in afresh: the container goes with it.
            sv.cmd({"do": "space", "action": "new", "name": "Two", "fresh": True})
            time.sleep(0.8)
            sv.cmd({"do": "space", "action": "go", "index": 1})
            time.sleep(0.8)
            sv.cmd({"do": "tospace", "id": w, "index": 2})
            time.sleep(0.5)
            sv.cmd({"do": "space", "action": "go", "index": 2})
            time.sleep(0.8)
            moved = tab(w)
            t.ok("moved to a space of its own sign-ins, it is still in Work",
                 moved is not None and moved["container"] == work and moved["store"] == work, moved)
            if moved:
                t.ok("…and signed in as Work there", who(w) == "work")
            sv.cmd({"do": "space", "action": "go", "index": 1})
            time.sleep(0.8)

            # Deleting a container: its tabs stay, in none.
            gone = box(action="delete", container=uni)
            t.ok("Uni is gone", [c["name"] for c in gone["containers"]] == ["Work"], gone["containers"])
            back = tab(u)
            t.ok("its pin stays, in no container", back is not None and back["container"] == "", back)
            if back:
                t.ok("…with the space's store, as the plain tab has",
                     back["store"] == tab(plain)["store"], (back["store"], tab(plain)["store"]))
                t.ok("…signed in as the plain tab is, not as Uni", who(u) == "plain")
            sv.sp("save")
            pins = json.load(open(f"{sv.SUPPORT}/pins.json"))
            kept = [p for defs in pins.values() for p in defs if "pin=uni" in p["home"]]
            t.ok("pins.json says no container for it now", [p.get("container") for p in kept] == [None], kept)
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
