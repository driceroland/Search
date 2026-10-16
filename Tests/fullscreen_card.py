#!/usr/bin/env python3
"""The column and the page's card, whole again after a page's full screen,
in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/fullscreen_card.py`.
Nothing goes full screen: the page's own word that it is going, and that it
is back (Forms.swift, "fullscreen"), is sent from Search's world, as in
full_screen_chrome.py. With Split View on, the pages' frames from the full
screen used to hold the stage at the whole window's width afterwards, and
the window's content, too wide, was centred in the window: the column cut
off at the left, the page past the right edge, the card's gap gone (Drice,
10 Oct 2026, after a YouTube video's full screen). Checked here: where the
page is, before and after, alone and as one of a pair, and that the
column, not the page, is under a point in the column. The real full
screen, a video's own, is checked by hand on a release candidate.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("fullscreen-card")


def immerse(tab, on):
    sv.cmd({"do": "eval", "id": tab, "world": "search",
            "js": f"window.webkit.messageHandlers.officeForms.postMessage({{kind: 'fullscreen', on: {'true' if on else 'false'}}}); 1"})
    time.sleep(1.5)


def page_frame():
    return sv.cmd({"do": "probe"}).get("activePageFrame")


def under(x):
    return sv.cmd({"do": "hit", "x": x, "y": 300})["view"]


def main():
    t = sv.T()
    try:
        for split, pair in ((False, False), (True, False), (True, True)):
            name = "a pair" if pair else ("Split View on" if split else "Split View off")
            sv.setup(sidebar=True, splitView=split); sv.launch()
            a = sv.page("a")
            if pair:
                b = sv.page("b")
                sv.sp("pair", id=b, **{"with": a}, side="right"); time.sleep(0.8)
                sv.sp("focus", id=a); time.sleep(0.4)
            time.sleep(0.8)
            side = sv.cmd({"do": "probe"})["sideWidth"]
            inside = int(side * 0.6)
            before = page_frame()
            column = under(inside)
            t.ok(f"{name}: the column is there", column not in ("PageView", "StageView"), column)
            immerse(a, True)
            immerse(a, False)
            after = page_frame()
            t.ok(f"{name}: the page is where it was", after == before, f"{before} -> {after}")
            windows = sv.cmd({"do": "probe"})["windows"]
            window = next((w for w in windows if w["kind"] == "AppKitWindow"), None)
            if window and after:
                t.ok(f"{name}: the page ends inside the window", after[0] + after[2] <= window["frame"][2], f"{after} in {window['frame']}")
            t.ok(f"{name}: the column, not the page, is under its middle", under(inside) == column, under(inside))
            sv.quit()
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
