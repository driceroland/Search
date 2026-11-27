#!/usr/bin/env python3
"""A peek's page is drawn on whole pixels, as sharp as the same page in a tab,
the panel still growing into place as it always has.

Build first (`./build.sh`), then `python3 Tests/peek_crisp.py`. A hidden
probe in a world of its own (split_view.py's harness).

Before: the panel grows into place from 98%, and the peek's web view is
given its size on its first frame, seen at 98%. WebKit draws the page in a
view of its own that fills the web view and is sized with it, which AppKit
put on the screen's pixels as seen at that moment: a fraction of a point
off the web view's bounds ((-0.357, -0.847, 838.776 × 683.673) in an
839 × 683 view). Nothing set it again once the panel was at full size, so
everything WebKit drew sat a fraction of a pixel off (0.42 at 1301 points
across), every line of text resampled and a little soft, until the
window's size next changed. PageView now gives a view meant to fill it
exactly its bounds when it is sized while seen scaled, as only a peek's
page is.

The probe reads how far the peek's page is from the screen's pixels: the
most any corner of WebKit's layers under it is off them (Bench "probe"
peekOffGrid), the page in front's the same way beside it, and where
WebKit's drawing lies in the peek's view (peekInner). At sizes that left
fractions before, in the column, as a card and with the tabs across the
top; after a pinch let go; when a peek that stays with its tab comes back
with it; and opened as a tab, or kept beside the page.

And pages in Split View, seen at their own size, are left as AppKit puts
them: a side half a point wide has WebKit's view sized a little off its
own, on whole pixels, and giving it the page's bounds put it half a pixel
off (1200 × 760, on a 1x screen).
"""
import os, sys, time, json
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("peek-crisp")
t = sv.T()
SIZES = [(1200, 760), (1237, 803), (1111, 689), (1301, 777)]


def start(**prefs):
    sv.setup(**prefs)
    os.makedirs(sv.SUPPORT, exist_ok=True)
    json.dump({"tabs": [{"url": f"{sv.BASE}/tall", "title": "tall"}], "active": 0},
              open(f"{sv.SUPPORT}/session.json", "w"))
    sv.launch()


def peek_up():
    sv.cmd({"do": "peek", "url": f"{sv.BASE}/peeked"})
    time.sleep(1.2)  # come in and settled


def crisp(what, key="peekOffGrid"):
    p = sv.cmd({"do": "probe"})
    t.ok(f"{what}: on whole pixels", p.get(key, 1) < 0.02, {key: p.get(key)})
    if key == "peekOffGrid":
        inner = p.get("peekInner", [])
        t.ok(f"{what}: WebKit's drawing fills its view exactly",
             len(inner) == 4 and all(abs(v) < 0.01 for v in inner), inner)


try:
    for name, prefs in [("column", {"sidebar": True}), ("column, cards", {"sidebar": True, "layout.cards": True}),
                        ("tabs across the top", {"sidebar": False})]:
        start(**prefs)
        for w, h in SIZES:
            sv.cmd({"do": "resize", "width": w, "height": h, "steps": 1}); time.sleep(0.8)
            peek_up()
            crisp(f"{name}, {w}×{h}: the page in front", "pageOffGrid")
            crisp(f"{name}, {w}×{h}: the peek's page")
            sv.cmd({"do": "peek", "url": "close"}); time.sleep(0.6)
        sv.quit()

    start(sidebar=True)
    sv.cmd({"do": "resize", "width": 1301, "height": 777, "steps": 1}); time.sleep(0.8)
    peek_up()
    sv.cmd({"do": "peek", "pinch": [0.05, 0.05, 0.05]}); time.sleep(1.0)
    crisp("a small pinch let go: the peek's page")
    # Settings › Keyboard & Mouse › Peek stays with its tab: another tab
    # hides it, and coming back brings it in again.
    sv.cmd({"do": "ui", "peekstays": True})
    first = sv.cmd({"do": "tabs"})["tabs"][0]["id"]
    other = sv.cmd({"do": "open", "url": f"{sv.BASE}/a"})["id"]; time.sleep(1.0)
    sv.cmd({"do": "select", "id": other}); time.sleep(0.8)
    shown = sv.cmd({"do": "probe"})["peekShown"]
    sv.cmd({"do": "select", "id": first}); time.sleep(1.2)
    p = sv.cmd({"do": "probe"})
    t.ok("peek stays: hidden behind another tab, then back", not shown and p["peekShown"], (shown, p["peekShown"]))
    crisp("peek stays, back with its tab: the peek's page")
    sv.quit()

    # Opened as a tab, and kept beside the page: the page it becomes.
    start(sidebar=True, splitView=True)
    sv.cmd({"do": "resize", "width": 1301, "height": 777, "steps": 1}); time.sleep(0.8)
    peek_up()
    sv.cmd({"do": "ui", "peeklink": "keep"}); time.sleep(1.2)
    crisp("opened as a tab: its page", "pageOffGrid")
    peek_up()
    sv.cmd({"do": "ui", "peeklink": "beside"}); time.sleep(1.2)
    crisp("kept beside the page: its page", "pageOffGrid")
    sv.quit()

    # Split View, no peek: a side half a point wide has its page put on whole
    # pixels by AppKit, WebKit's view sized a little off the page's own. Seen
    # at its own size, that is left as it is.
    start(sidebar=True, splitView=True)
    a, b = sv.page("a"), sv.page("b")
    sv.sp("pair", id=b, **{"with": a}, side="right"); time.sleep(0.8)
    for w, h in SIZES + [(1201, 761), (1203, 763)]:
        sv.cmd({"do": "resize", "width": w, "height": h, "steps": 1}); time.sleep(0.8)
        for side, id in (("left", a), ("right", b)):
            sv.cmd({"do": "select", "id": id}); time.sleep(0.4)
            crisp(f"Split View, {w}×{h}: the {side} page", "pageOffGrid")
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
