#!/usr/bin/env python3
"""Controls over a page in Split View, with the setting on, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/split_controls.py`. Uses the
split suite's harness: hidden, nothing shown, everything removed afterwards.
The pointer coming to rest on a page is told to the stage itself (`hover`),
and where the capsule would be is hit-tested (`hit`): no real pointer moves.
Off, the default, nothing is drawn over the page. On, the capsule is there
over the page under the pointer alone, and what its buttons call is driven
through the bench: Move Left and Right (`moveIn`), Remove from Split View
(`leave`), Close Tab (`closeTab`). A hidden window's SwiftUI buttons take no
clicks handed to them, so a click on the capsule itself is checked by hand.
"""
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("split-controls")

# The capsule (SplitControls.swift): four 26-point buttons 2 apart, 4 in from
# its ends, centred over the page's top, 8 below it.
BUTTONS = {"left": -42, "right": -14, "out": 14, "close": 42}


def under(st, tab, button, hover=True):
    """What a press on `button` of the capsule over `tab` would land on, the
    pointer first resting on that page (or, `hover` False, gone from the
    pages): SwiftUI's view where the capsule is drawn, the page where not."""
    sv.sp("hover", **({"id": tab} if hover else {})); time.sleep(0.4)
    f = sv.frames(st)[tab]
    x, y = f["x"] + f["width"] / 2 + BUTTONS[button], f["y"] + 8 + 15
    return sv.cmd({"do": "hit", "x": x, "y": y})["view"]


def capsule(view): return view.startswith("AppKitWindowHostingView")


def split_of(st, tab): return next((s for s in st["splits"] if tab in s["tabs"]), None)


def pair(a, b):
    sv.sp("pair", id=b, **{"with": a}, side="right"); time.sleep(0.8)
    return sv.sp("state")


def main():
    t = sv.T()
    try:
        sv.setup(splitView=True); sv.launch()
        found = sv.cmd({"do": "settings", "find": "split controls"})["found"]
        t.ok("Settings finds Controls over a page in Split View",
             any("split.controls" in i["keys"] for i in found), [i["id"] for i in found])
        stored = subprocess.run(["defaults", "read", sv.SUITE, "split.controls"], capture_output=True, text=True)
        t.ok("off by default: nothing written", stored.returncode != 0, stored.stdout)
        a = sv.page("a"); b = sv.page("b")
        st = pair(a, b)
        t.ok("a pair [a, b]", (split_of(st, a) or {}).get("tabs") == [a, b], st["splits"])
        hits = [under(st, a, k) for k in BUTTONS]
        t.ok("off: nothing over the page under the pointer", not any(capsule(v) for v in hits), hits)
    finally:
        sv.finish()
    try:
        sv.setup(splitView=True, **{"split.controls": True}); sv.launch()
        a = sv.page("a"); b = sv.page("b"); c = sv.page("c")
        st = pair(a, b)
        hits = [under(st, a, k) for k in BUTTONS]
        t.ok("on: the capsule's four buttons over the page under the pointer", all(capsule(v) for v in hits), hits)
        v = under(st, b, "right", hover=False)
        t.ok("…over no other page", not capsule(v), v)
        v = under(st, a, "close", hover=False)
        t.ok("…and gone with the pointer", not capsule(v), v)
        v = under(st, b, "close")
        t.ok("…then over the other page, once the pointer is there", capsule(v), v)
        sid = split_of(st, a)["id"]
        sv.sp("sizes", split=sid, sizes=[0.3, 0.7])
        st = sv.sp("moveIn", id=a, by=1)
        p = split_of(st, a) or {}
        t.ok("Move Right: [b, a]", p.get("tabs") == [b, a], p)
        t.ok("…each page keeps its width", p.get("sizes") and abs(p["sizes"][0] - 0.7) < 1e-6, p.get("sizes"))
        t.ok("…and the column follows", sv.order(st).index(b) < sv.order(st).index(a), sv.order(st))
        st = sv.sp("moveIn", id=b, by=-1)
        t.ok("already leftmost: nothing moves", (split_of(st, a) or {}).get("tabs") == [b, a], st["splits"])
        st = sv.sp("moveIn", id=a, by=-1)
        t.ok("Move Left: [a, b] again", (split_of(st, a) or {}).get("tabs") == [a, b], st["splits"])
        st = pair(b, c)
        t.ok("three: [a, b, c]", (split_of(st, a) or {}).get("tabs") == [a, b, c], st["splits"])
        st = sv.sp("moveIn", id=a, by=1)
        t.ok("of three, only a and its neighbour change places", (split_of(st, a) or {}).get("tabs") == [b, a, c], st["splits"])
        st = sv.sp("moveIn", id=c, by=1)
        t.ok("already rightmost: nothing moves", (split_of(st, a) or {}).get("tabs") == [b, a, c], st["splits"])
        st = sv.sp("closeTab", id=c)
        t.ok("Close Tab: c closed", not any(x["id"] == c for x in st["tabs"]), sv.order(st))
        t.ok("…the other two stay together", (split_of(st, a) or {}).get("tabs") == [b, a], st["splits"])
        st = sv.sp("leave", id=b)
        t.ok("Remove from Split View: no split left", not st["splits"], st["splits"])
        t.ok("…both pages still open", {a, b} <= set(sv.order(st)), sv.order(st))
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
