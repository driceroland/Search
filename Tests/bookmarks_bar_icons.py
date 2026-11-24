#!/usr/bin/env python3
"""The bookmarks bar's Show icons only (idea 980), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/bookmarks_bar_icons.py`.
It uses the split suite's harness: started hidden in a world of its own, no
window shown or brought forward, everything removed afterwards. The window
is sized while hidden (bench `bar` width), on no screen. With PICTURES=dir,
a PNG of the bar off, on, and overflowing is left there.

Off, every bookmark shows its name, as before. On, each bookmark is its
icon alone — the site's first letter where no icon is kept — in a square as
tall as the bar's others, its name on hover; folders keep their names. The
» still takes exactly what the narrower row has no room for.
"""
import json
import os
import sys
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bookmarks-bar-icons")
PICTURES = os.environ.get("PICTURES")


def mark(title, url):
    return {"id": str(uuid.uuid4()).upper(), "title": title, "url": url}


def folder(title, children):
    return {"id": str(uuid.uuid4()).upper(), "title": title, "children": children}


def world(roots):
    os.makedirs(sv.SUPPORT, exist_ok=True)
    json.dump(roots, open(f"{sv.SUPPORT}/bookmarks.json", "w"))


def bar(**f):
    if PICTURES and "shot" in f:
        f["path"] = f"{PICTURES}/bar-{f.pop('shot')}.png"
    f.pop("shot", None)
    return sv.cmd({"do": "bar", **f})


def main():
    t = sv.T()
    try:
        few = [folder("Work", [mark("Inside", f"{sv.BASE}/in")]),
               mark("Alpha site", f"{sv.BASE}/a"),
               mark("", f"{sv.BASE}/unnamed"),
               mark("Beta site with a longer name", "http://localhost:1/b"),
               folder("Reading", [mark("R1", f"{sv.BASE}/r1")])]
        sv.setup(sidebar=False, **{"bookmarks.bar": True})
        world(few)
        sv.launch()

        off = bar(width=1100, shot="off")
        w = [f[2] for f in off["frames"]]
        t.ok("off by default", off["iconsOnly"] is False, off)
        t.ok("off: named bookmarks show their names (wider than a square)", w[1] > 40 and w[3] > 40, w)
        t.ok("off: one renamed to nothing is still its icon alone (idea 334)", abs(w[2] - 22) < 0.5, w)
        t.ok("off: tooltips are addresses, as before", off["tips"][1].endswith("/a") and off["tips"][0] == "Work", off["tips"])

        on = bar(iconsOnly=True, shot="on")
        v = [f[2] for f in on["frames"]]
        t.ok("on: every bookmark is a 22-point square", all(abs(v[i] - 22) < 0.5 for i in (1, 2, 3)), v)
        t.ok("on: folders keep their names", v[0] > 40 and v[4] > 40 and abs(v[0] - w[0]) < 0.5, (v, w))
        t.ok("on: the bar is as tall as before", all(abs(a[3] - b[3]) < 0.5 for a, b in zip(on["frames"], off["frames"])), on["frames"])
        t.ok("on: a bookmark's tooltip is its name", on["tips"][1] == "Alpha site" and on["tips"][3] == "Beta site with a longer name", on["tips"])
        t.ok("on: one without a name says its address", "127.0.0.1" in on["tips"][2] and on["tips"][2].endswith("/unnamed"), on["tips"])
        t.ok("on: a folder's tooltip is its name", on["tips"][0] == "Work" and on["tips"][4] == "Reading", on["tips"])
        t.ok("on: nothing goes to the » with room for all", on["hidden"] == [], on)
        t.ok("the bar picture was taken", not PICTURES or on["saved"], on.get("saved"))

        back = bar(iconsOnly=False)
        t.ok("off again: names come back", [f[2] for f in back["frames"]] == w, ([f[2] for f in back["frames"]], w))
        sv.quit()

        # Overflow with the narrower items: 80 bookmarks and a folder.
        many = [mark(f"Bookmark number {i}", f"{sv.BASE}/m{i}") for i in range(80)]
        many.insert(40, folder("Deep", [mark("Deep 1", f"{sv.BASE}/deep1")]))
        sv.setup(sidebar=False, **{"bookmarks.bar": True, "bookmarks.iconsOnly": True})
        world(many)
        sv.launch()
        b = bar(width=900, shot="overflow")
        roots, hidden, frames = b["roots"], b["hidden"], b["frames"]
        k = len(roots) - len(hidden)
        t.ok("icons only, read from Settings at launch", b["iconsOnly"] is True, b)
        t.ok("eighty-one at 900 points: some go to the »", 0 < len(hidden) < len(roots), (k, len(roots)))
        t.ok("…far more stay on the bar than with names (over 25)", k > 25, k)
        t.ok("the » holds exactly the last ones, in order", hidden == roots[k:], (roots[k:k + 3], hidden[:3]))
        t.ok("the last one shown ends before the »", frames[k - 1][0] + frames[k - 1][2] <= 900 - 10 - 26 + 0.5, frames[k - 1])
        t.ok("the next one wouldn't have fitted", frames[k][0] + frames[k][2] > 900 - 10 - 26, frames[k])
        top = [m["title"] for m in b["menu"] if m["depth"] == 0]
        t.ok("the » menu lists the hidden ones by name", top == hidden, (top[:3], hidden[:3]))
        p = bar(pick=hidden[-1])
        t.ok("a bookmark picked from the » opens", p["active"].endswith("/m79"), p["active"])
        names = bar(iconsOnly=False)
        t.ok("with names again, more go to the »", len(names["hidden"]) > len(hidden), (len(names["hidden"]), len(hidden)))
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
