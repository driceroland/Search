#!/usr/bin/env python3
"""The bookmark button's list, sized for the tree, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/bookmarks_dropdown.py`. A
tree like one brought in from Dia — one folder of 109 with a folder of 22
inside it — is taken in from a file, and the list is laid out off every
screen (bench `dropdown`); no popover or window is opened. The popover
takes its height once, as it opens, and doesn't grow with a folder opened
in it: sized by the rows it showed then, one closed folder, the list was a
row high and the folder opened into a sliver (reported on 1.0.4). Now it is
as tall as the tree with every folder open, up to 360 points, and a top
level that is one folder alone opens open, so that height is filled.
"""
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402


def netscape(tree):
    def items(nodes, depth):
        out = []
        pad = "    " * depth
        for n in nodes:
            if isinstance(n, tuple):
                out.append(f"{pad}<DT><H3>{n[0]}</H3>\n{pad}<DL><p>")
                out += items(n[1], depth + 1)
                out.append(f"{pad}</DL><p>")
            else:
                out.append(f'{pad}<DT><A HREF="{n}">{n.split("/")[-1]}</A>')
        return out
    return "\n".join(["<!DOCTYPE NETSCAPE-Bookmark-file-1>", "<TITLE>Bookmarks</TITLE>", "<H1>Bookmarks</H1>", "<DL><p>"]
                     + items(tree, 1) + ["</DL><p>"])


def take(tree):
    with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False) as f:
        f.write(netscape(tree))
    try:
        return sv.cmd({"do": "import-file", "path": f.name})
    finally:
        os.remove(f.name)


def main():
    t = sv.T()
    try:
        sv.setup(sidebar=True); sv.launch()
        few = [f"https://example.com/few{i}" for i in range(3)]
        took = take(few)
        d = sv.cmd({"do": "dropdown"})
        t.ok("three bookmarks: the list is as tall as its three rows", 0 <= d["list"] - d["allOpen"] <= 4 and d["list"] < 120, (took.get("total"), d))

        sv.setup(sidebar=True); sv.launch()
        personal = ("Personal", [f"https://example.org/personal{i}" for i in range(22)])
        dia = ("Dia", [f"https://example.com/dia{i}" for i in range(87)] + [personal])
        took = take([dia])
        t.ok("the Dia-like tree came in", took.get("total") == 109 and took.get("top") == ["Dia"], took)
        d = sv.cmd({"do": "dropdown"})
        t.ok("closed, the tree shows one row (what the list was once sized by)", d["closed"] < 50, d)
        t.ok("the list is its full 360 points from the start", d["list"] == 360, d)
        t.ok("the dropdown is the list and its foot", d["height"] >= 360 + 60, d)
        t.ok("a top level of one folder opens with it open, and fills the list", d["opening"] == 1 and d["shown"] >= d["list"], d)

        sv.setup(sidebar=True); sv.launch()
        small = ("Work", [f"https://example.com/w{i}" for i in range(4)] + [("Empty one", [])])
        take([small])
        d = sv.cmd({"do": "dropdown"})
        t.ok("a small folder: tall enough for it opened, not more", 0 <= d["list"] - d["allOpen"] <= 4 and d["list"] < 360, d)
        # Only the top folder opens: the empty one inside stays closed, one
        # "Empty" line short of the list's height for everything open.
        t.ok("…and alone at the top, it opens open", d["opening"] == 1 and d["closed"] < d["shown"] and d["list"] - d["shown"] <= 30, d)

        sv.setup(sidebar=True); sv.launch()
        take([("A", ["https://example.com/a1"]), ("B", ["https://example.com/b1"])])
        d = sv.cmd({"do": "dropdown"})
        t.ok("two folders at the top: both start closed, as before", d["opening"] == 0, d)
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
