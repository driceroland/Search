#!/usr/bin/env python3
"""The page follows the column as ⌘S slides it, frame by frame (idea 659).

Build first (`./build.sh`), then `python3 Tests/fold_follow.py`. A hidden
probe in a world of its own (split_view.py's harness) shows one page, and
Bench "foldframes" stages its window far off every screen, where it is drawn
at the display's pace and never seen, and presses ⌘S, timing every display
frame. On each frame it reads where Core Animation shows the column's edge
and three of the page's own layers: a box the page centres, one against its
left edge and one fixed to its right edge.

Up to 1.0.17 the page was resized once per slide: going away, to its new
width before the column moved, coming out, after the column had stopped.
Anything the page centres (most sites' content) jumped half the column's
width, 112 points, in one frame while the column stood still. It is now laid
out at the width the column leaves it on every frame of the slide, as Safari
and Dia do. Checked, with Slide the column in and out off (springs) and on,
the page as a card and edge to edge:

- before the column moves, and two frames after it rests, the page's content
  is still (but for a settle of a point or two);
- on each frame the centred box moves by half what the column moved, give or
  take what WebKit lags behind by a frame (30 points at 120 Hz, never 60% of
  the jump it replaces; 1.0.17: 112, all in one frame);
- the left box keeps to the column's edge;
- where the growing page isn't drawn yet, its ground is the page's own
  colour: the page is dark, the theme light, and the web view's own white
  ground showed there as a sliver at the far edge;
- the pointer at the edge (the column out over the page and back) leaves the
  page where it is, at its width.
"""
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("fold-follow")
t = sv.T()

PAGE = (b"<!doctype html><title>follow</title><style>html,body{margin:0;background:#123}"
        b"#c{width:333px;height:77px;margin:40px auto;background:#08f;will-change:transform}"
        b"#l{width:111px;height:55px;background:#f80;will-change:transform}"
        b"#r{position:fixed;right:0;top:300px;width:7px;height:13px;background:#0f0;will-change:transform}</style>"
        b"<div id=l></div><div id=r></div><div id=c></div>")
TRACK = [[333, 77], [111, 55], [7, 13]]
# What WebKit's frame of lag may move the centred box past where it belongs.
LAG = 30

served = sv.H.do_GET


def do_GET(self):
    if self.path != "/follow":
        return served(self)
    self.send_response(200); self.send_header("Content-Type", "text/html")
    self.send_header("Content-Length", str(len(PAGE))); self.end_headers(); self.wfile.write(PAGE)


sv.H.do_GET = do_GET


def frames(press):
    return [s for s in press["seen"] if "m0" in s and "m1" in s and s["col"] == s["col"]]


def check_press(name, press):
    S = frames(press)
    if len(S) < 10:
        t.ok(f"{name}: frames seen", False, len(S)); return
    moving = [i for i, (a, b) in enumerate(zip(S, S[1:])) if abs(b["col"] - a["col"]) > 0.01]
    first, last = (moving[0], moving[-1] + 1) if moving else (len(S), len(S))
    still = [(a["t"], a["m0"], b["m0"]) for a, b in zip(S[:first], S[1:first + 1]) if abs(b["m0"] - a["m0"]) > 1]
    t.ok(f"{name}: nothing moves on the page before the column does", not still, still[:3])
    # WebKit's lag: the page may settle on the two frames after, and by a
    # point or two a little later.
    after = [(a["t"], a["m0"], b["m0"]) for a, b in zip(S[last + 2:], S[last + 3:]) if abs(b["m0"] - a["m0"]) > 3]
    t.ok(f"{name}: …nor once it rests, but for WebKit's lag settling", not after, after[:3])
    errors = [(round(abs((b["m0"] - a["m0"]) - (b["col"] - a["col"]) / 2), 1), b["t"]) for a, b in zip(S, S[1:])]
    worst = max(errors)
    # A frame of lag is worth half the column's step on that frame: more on
    # a 60 Hz display than at 120. Never as much as the jump it replaces.
    half = abs(S[-1]["col"] - S[0]["col"]) / 2
    step = max(abs(b["col"] - a["col"]) for a, b in zip(S, S[1:]))
    lag = min(0.6 * half, max(LAG, 0.8 * step))
    print(f"    {name}: worst frame {worst[0]} pt off the column's pace at {worst[1]} ms, {len(moving)} frames moving"
          f" (allowed {lag:.0f}; the jump was {half:.0f})")
    t.ok(f"{name}: what the page centres moves with the column, frame by frame", worst[0] <= lag, (worst, lag))
    edge = S[0]["m1"] - S[0]["col"]
    off = max(abs((s["m1"] - s["col"]) - edge) for s in S[first:last + 1]) if moving else 0
    t.ok(f"{name}: what lies at the page's left edge keeps to the column's", off <= 10, off)
    end = S[-1]
    t.ok(f"{name}: the centred box ends in the middle of the page",
         abs((end["m0"] + 333 / 2) - (end["x"] + end["w"] / 2)) <= 1, (end["m0"], end["x"], end["w"]))
    bare = [(s["t"], round((s["x"] + s["w"]) - (s["m2"] + 7), 1)) for s in S
            if "m2" in s and (s["x"] + s["w"]) - (s["m2"] + 7) > 0.5 and not s.get("groundIsPage")]
    t.ok(f"{name}: room the page hasn't drawn yet is in the page's colour", not bare, bare[:4])


def check_peek(name, press):
    S = frames(press)
    moved = {(round(s["m0"], 1), round(s["x"], 1), round(s["w"], 1)) for s in S}
    t.ok(f"{name}: the page stays where it is, at its width", len(moved) == 1 and len(S) >= 10, sorted(moved)[:4])
    t.ok(f"{name}: …and the column moved over it", len({round(s["col"]) for s in S}) > 5)


def run(layout):
    for slides in (False, True):
        mode = f"{layout}, {'slide' if slides else 'springs'}"
        a = sv.cmd({"do": "foldframes", "times": 2, "slides": slides, "track": TRACK, "span": 0.6})
        hide, show = a["presses"]
        t.ok(f"{mode}: hidden, then shown", not hide["was"] and hide["folded"] and show["was"] and not show["folded"],
             [(p["was"], p["folded"]) for p in a["presses"]])
        check_press(f"{mode} hide", hide)
        check_press(f"{mode} show", show)
        # Folded, the pointer at the edge brings the column over the page.
        sv.cmd({"do": "foldframes", "times": 1, "slides": slides})
        b = sv.cmd({"do": "foldframes", "times": 2, "slides": slides, "track": TRACK, "peek": True, "span": 0.5})
        check_peek(f"{mode} edge", b["presses"][0])
        check_peek(f"{mode} edge, back in", b["presses"][1])
        sv.cmd({"do": "foldframes", "times": 1, "slides": slides})


def world():
    os.makedirs(sv.SUPPORT, exist_ok=True)
    json.dump({"tabs": [{"url": f"{sv.BASE}/follow", "title": "follow"}], "active": 0},
              open(f"{sv.SUPPORT}/session.json", "w"))


try:
    for layout, prefs in (("card", {"sidebar": True}), ("edge to edge", {"sidebar": True, "layout.cards": False})):
        sv.setup(**prefs)
        world()
        sv.launch()
        sv.cmd({"do": "resize", "width": 1280, "height": 820, "steps": 1})
        time.sleep(2)
        sv.cmd({"do": "foldframes", "times": 2, "slides": False})  # staged, warmed up
        run(layout)
        sv.quit()
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
