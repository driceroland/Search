#!/usr/bin/env python3
"""A new tab's site tiles (HomeTiles.swift, idea 1285), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/home_tiles.py`. Hidden: no
window is made, shown or brought forward, no menu is opened, and nothing
plays sound. Through the bench's `tiles` verb, which calls what the tiles
themselves call: adds (typed and from the page you're on), edits,
reorders and removes; refuses what isn't a website; a private tab changes
nothing; and opening new tabs asks the site for nothing.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("home-tiles")

# Every request the local site gets, by path.
asked = []
_get = sv.H.do_GET


def counted(self):
    asked.append(self.path)
    return _get(self)


sv.H.do_GET = counted


def tiles(action="list", **f):
    return sv.cmd({"do": "tiles", "action": action, **f})


def names(r):
    return [t["name"] for t in r["tiles"]]


def main():
    t = sv.T()
    try:
        sv.setup()
        sv.launch()

        r = tiles()
        t.ok("off by default: nothing shown, nothing editable", not r["showing"] and not r["editable"] and r["count"] == 0, r)
        r = tiles("add", name="A", url=f"{sv.BASE}/a")
        t.ok("off, nothing kept and no folder made", r["problem"] == "notAddress" and r["folder"] == "" and not r["tiles"], r)

        tiles("on")
        tiles("newtab")
        r = tiles()
        t.ok("on: a new tab shows the + alone", r["showing"] and r["editable"] and r["count"] == 1, r)

        before = len(asked)
        r = tiles("add", name="  Local\nsite ", url=f"{sv.BASE}/a")
        t.ok("added by its address, the name cleaned", r["problem"] == "" and names(r) == ["Local site"] and r["folder"] == "Home", r)
        time.sleep(1.5)
        icon_asks = [p for p in asked[before:] if p == "/favicon.ico"]
        t.ok("its icon asked for once, when added", len(icon_asks) == 1, asked[before:])

        for bad in ["javascript:alert(1)", "data:text/html,<b>x</b>", "file:///etc/passwd", "about:blank",
                    "blob:https://example.com/x", "chrome-extension://abc/p.html", "search://settings",
                    "https://bank.example@evil.example/", "hello world", "https://x.example/" + "a" * 3000]:
            r = tiles("add", name="Bad", url=bad)
            t.ok(f"refused: {bad[:40]}", r["problem"] != "" and names(r) == ["Local site"], r["problem"])

        page = sv.page("b")
        r = tiles("add", page=True, id=page)
        t.ok("the page you're on, added from its tab", r["problem"] == "" and len(r["tiles"]) == 2 and r["tiles"][1]["url"].endswith("/b"), r)
        r = tiles("add", page=True, id=page)
        t.ok("and not twice", r["problem"] == "already" and len(r["tiles"]) == 2, r)

        tiles("add", name="C", url=f"{sv.BASE}/c")
        tiles("add", name="D", url=f"{sv.BASE}/d")
        r = tiles("edit", at=0, name="<img src=x onerror=alert(1)>", url=f"{sv.BASE}/a2")
        t.ok("edited: the name kept as plain text, the address changed", r["problem"] == "" and r["tiles"][0]["name"] == "<img src=x onerror=alert(1)>" and r["tiles"][0]["url"].endswith("/a2"), r["tiles"][0])
        r = tiles("edit", at=0, url="javascript:alert(1)")
        t.ok("an edit to a script refused, nothing changed", r["problem"] == "scheme" and r["tiles"][0]["url"].endswith("/a2"), r)

        r = tiles("move", at=0, to=3)
        order = names(r)
        t.ok("moved to the end", order[-1] == "<img src=x onerror=alert(1)>" and len(order) == 4, order)
        r = tiles("move", at=3, to=0)
        t.ok("and back", names(r)[0] == "<img src=x onerror=alert(1)>", names(r))
        r = tiles("move", at=1, to=2)
        t.ok("two in the middle swapped", names(r)[1:3] == [order[1], order[0]] or names(r)[2] == order[0], names(r))

        r = tiles("remove", at=3)
        t.ok("removed", len(r["tiles"]) == 3 and "D" not in names(r), names(r))

        # New tabs, many: the site is asked for nothing.
        before = len(asked)
        for _ in range(8):
            tiles("newtab")
            time.sleep(0.2)
        r = tiles()
        time.sleep(1.0)
        t.ok("still showing on a new tab", r["showing"] and r["blank"], r)
        t.ok("no request to any site for 8 new tabs", asked[before:] == [], asked[before:])
        t.ok("no icon fetch started by them", r["fetches"] == 2 or r["fetches"] == 1, r["fetches"])

        # A private tab: shown, not changed, nothing fetched.
        before = len(asked)
        tiles("private")
        r = tiles()
        t.ok("a private tab shows them, without the +", r["shy"] and r["showing"] and not r["editable"] and r["count"] == 3, r)
        r = tiles("add", name="E", url="e.example")
        t.ok("nothing added from a private tab", r["problem"] == "notAddress" and len(r["tiles"]) == 3, r)
        r = tiles("remove", at=0)
        t.ok("nothing removed from a private tab", r.get("problem") == "notEditable" and len(r["tiles"]) == 3, r)
        r = tiles("move", at=0, to=2)
        t.ok("nothing moved from a private tab", r.get("problem") == "notEditable", r)
        time.sleep(0.5)
        t.ok("a private tab asks the site for nothing", asked[before:] == [], asked[before:])

        tiles("newtab")
        tiles("off")
        r = tiles()
        t.ok("off again: no tiles, not editable", not r["showing"] and not r["editable"] and r["count"] == 0, r)
        t.ok("the folder is the plain Home grid again (home.grid, as before)", r["height"] == 50, r["height"])
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
