#!/usr/bin/env python3
"""A bookmark without a name, and the icons of bookmarks in folders.

Build first (`./build.sh`), then `python3 Tests/bookmark_names.py`. The app
is started hidden in a world of its own, with a few bookmarks written to its
file — named ones, some whose name is empty, a folder and a folder inside
it — and icons kept for some of their sites only. Asked for on X: a bookmark
whose name is emptied is its icon alone on the bookmarks bar, as in Chrome
and Safari, and bookmarks in a folder wear their icons in its menu.

Checked through bench `marks`, nothing drawn on a screen: the bar's buttons
laid out off every screen (an unnamed one is a square as tall as the rest),
every folder's menu and the Bookmarks menu with each folder opened (each
bookmark has an image, the site's or the bar's letter, and reads as a name
or its address), and the button's list. A name emptied in the ⇧⌘B card
stays empty after a relaunch. `--pictures DIR` saves what it looks like.
"""
import json
import os
import struct
import sys
import time
import uuid
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bm-names")


def png(rgb, size=32):
    """A square of one colour, as a site's icon."""
    row = b"\x00" + bytes(rgb) * size
    chunk = lambda kind, data: struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(row * size)) + chunk(b"IEND", b""))


node = lambda **f: {"id": str(uuid.uuid4()).upper(), **f}
TREE = [
    node(title="Alpha", url="https://alpha.example/"),
    node(title="", url="https://github.com/"),
    node(title="", url="https://never.example/"),
    node(title="Beta", url="https://beta.example/"),
    node(title="Work", children=[
        node(title="Docs", url="https://docs.example/"),
        node(title="", url="https://linear.example/"),
        node(title="Deep", children=[
            node(title="Inner", url="https://inner.example/"),
            node(title="Unvisited", url="https://unvisited.example/"),
        ]),
    ]),
]
# Icons kept for every site but never. and unvisited., which wear a letter.
ICONS = {"alpha.example": (230, 80, 60), "github.com": (30, 30, 30), "beta.example": (60, 120, 230),
         "docs.example": (40, 170, 90), "linear.example": (110, 90, 220), "inner.example": (240, 170, 30)}


def marks(**f):
    return sv.cmd({"do": "marks", **f})


def items_ok(items):
    """Every bookmark in a menu has an image and reads as something."""
    pages = [i for i in items if not i["folder"]]
    return bool(pages) and all(i["image"] and i["title"].strip() for i in pages)


def main():
    pictures = sys.argv[sys.argv.index("--pictures") + 1] if "--pictures" in sys.argv else None
    t = sv.T()
    try:
        sv.setup(**{"bookmarks.bar": True})
        os.system(f"defaults write {sv.SUITE} look -string light")
        os.makedirs(f"{sv.SUPPORT}/icons", exist_ok=True)
        json.dump(TREE, open(f"{sv.SUPPORT}/bookmarks.json", "w"))
        for host, rgb in ICONS.items():
            open(f"{sv.SUPPORT}/icons/{host}.png", "wb").write(png(rgb))
        sv.launch()

        m = marks()
        bar = {b["label"]: b for b in m["bar"]}
        t.ok("an empty name reads as the address", "github.com" in bar and "never.example" in bar, list(bar))
        named, square = bar["Alpha"], bar["github.com"]
        t.ok("unnamed on the bar: a square, as tall as a named one",
             square["unnamed"] and abs(square["width"] - square["height"]) <= 1 and square["height"] == named["height"], (square, named))
        t.ok("unnamed, no icon kept: the same square", abs(bar["never.example"]["width"] - square["width"]) <= 1, bar["never.example"])
        t.ok("a named one is wider than its icon", named["width"] > square["width"] + 20, named)

        work = next(f for f in m["folders"] if f["folder"] == "Work")["items"]
        deep = [i for i in work if i["depth"] == 1]
        t.ok("the bar's folder: every bookmark has its icon or the letter", items_ok(work), work)
        t.ok("the bar's folder: the folder inside it, its bookmarks with images",
             [i["title"] for i in deep] == ["Inner", "Unvisited"] and items_ok(deep), deep)
        t.ok("the bar's folder: an unnamed one reads as its address", any(i["title"] == "linear.example" for i in work), work)

        menu = m["menu"]
        t.ok("the Bookmarks menu: all 8 bookmarks, folders opened, with images",
             items_ok(menu) and len([i for i in menu if not i["folder"]]) == 8, menu)
        t.ok("the Bookmarks menu: two deep", any(i["depth"] == 2 and i["title"] == "Inner" for i in menu), menu)
        t.ok("the Bookmarks menu: unnamed ones read as their address",
             {"github.com", "never.example", "linear.example"} <= {i["title"] for i in menu}, menu)

        rows = m["list"]
        t.ok("the list: every row reads as something", all(r["label"].strip() for r in rows), rows)
        t.ok("the list: kept icons found two deep", any(r["depth"] == 2 and r["icon"] for r in rows), rows)

        # The ⇧⌘B card's Name field: emptied, and only spaces.
        marks(rename=["https://beta.example/", ""])
        marks(rename=["https://alpha.example/", "   "])
        bar = {b["label"]: b for b in marks()["bar"]}
        t.ok("emptied in the card: kept empty, its icon alone",
             bar.get("beta.example", {}).get("unnamed") and bar.get("alpha.example", {}).get("unnamed"), list(bar))
        sv.quit()
        saved = json.load(open(f"{sv.SUPPORT}/bookmarks.json"))
        t.ok("saved empty", [n["title"] for n in saved[:4]] == ["", "", "", ""], [n["title"] for n in saved])
        sv.launch()
        m = marks()
        t.ok("after a relaunch: still empty, still a square",
             [b["unnamed"] for b in m["bar"][:4]] == [True] * 4 and abs(m["bar"][3]["width"] - m["bar"][3]["height"]) <= 1, m["bar"])
        marks(rename=["https://alpha.example/", "Alpha"])
        marks(rename=["https://beta.example/", "Beta"])
        b = marks()["bar"][0]
        t.ok("named again: its name on the bar again", b["title"] == "Alpha" and not b["unnamed"], b)

        if pictures:
            os.makedirs(pictures, exist_ok=True)
            shot = sv.cmd({"do": "picture", "path": f"{pictures}/marks-bar.png", "page": False})
            marks(path=f"{pictures}/marks-folder.png")
            t.ok("pictures saved", os.path.exists(shot["saved"]) and os.path.exists(f"{pictures}/marks-folder.png"), shot)
    finally:
        t.done(); sv.finish()
        os.system(f"defaults delete {sv.SUITE} >/dev/null 2>&1; rm -f ~/Library/Preferences/{sv.SUITE}.plist")
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
