#!/usr/bin/env python3
"""The page as a card, and the page edge to edge, in a hidden probe (#607).

Build first (`./build.sh`), then `python3 Tests/edge_to_edge.py [PICTURES]`.
With the tabs down the side the page is a card on the window's ground
(Browser.asCards): a gap at the top, the far side and the bottom. Settings ›
Tabs › The page as a card off, or the window in macOS full screen, and the
page reaches the window's edges, the column beside it as before 1.0.5.
Nothing goes full screen here: `ui fullscreen` sets the window's full screen
as the chrome sees it (Browser.fullScreen), the window staying where it is.
Checked alone and as a pair in Split View, with the column out and folded,
and the tabs across the top, which never had a card. Given a folder, a
picture of each state goes there, light and dark; nothing is shown on any
screen to take them.
"""
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("edge-to-edge")
GAP = 8
PICTURES = sys.argv[1] if len(sys.argv) > 1 else None


def ui(**f):
    sv.cmd({"do": "ui", **f})
    time.sleep(0.9)


def state():
    p = sv.cmd({"do": "probe"})
    window = next(w for w in p["windows"] if w["kind"] == "AppKitWindow")
    return p, window["frame"][2], window["frame"][3]


def pages():
    """Each page on screen, from the window's top-left corner: x, y, right, bottom."""
    frames = sv.sp("state")["paneFrames"]
    return sorted((round(f["x"]), round(f["y"]), round(f["x"] + f["width"]), round(f["y"] + f["height"])) for f in frames)


def edges():
    """The room around the pages: left, top, right, bottom."""
    p, w, h = state()
    shown = pages()
    return (min(f[0] for f in shown), min(f[1] for f in shown),
            w - max(f[2] for f in shown), h - max(f[3] for f in shown)), p


def picture(name):
    if not PICTURES:
        return
    for look in ("light", "dark"):
        ui(look=look)
        path = f"{PICTURES}/edge-{name}-{look}.png"
        sv.cmd({"do": "picture", "path": path, "page": False})
    ui(look="system")


def main():
    t = sv.T()
    if PICTURES:
        os.makedirs(PICTURES, exist_ok=True)
    try:
        for split in (False, True):
            kind = "a pair" if split else "one page"
            sv.setup(sidebar=True, splitView=split); sv.launch()
            a = sv.page("a")
            if split:
                b = sv.page("b")
                sv.sp("pair", id=b, **{"with": a}, side="right"); time.sleep(0.8)
                sv.sp("focus", id=a); time.sleep(0.4)
            time.sleep(0.8)
            tag = "pair-" if split else ""
            p, w, _ = state()
            side = p["sideWidth"]
            if split:
                t.ok(f"{kind}: two pages up", len(pages()) == 2, pages())

            room, p = edges()
            t.ok(f"{kind}: on by default, with nothing in the settings",
                 p["cards"] == {"switch": True, "fullScreen": False, "on": True, "windowFullScreen": False}, p["cards"])
            t.ok(f"{kind}: a card, with room around it", room == (side, GAP, GAP, GAP), room)
            card = pages()
            picture(f"{tag}card-on")

            ui(cards=False)
            room, p = edges()
            t.ok(f"{kind}: off, no card", p["cards"]["on"] is False, p["cards"])
            t.ok(f"{kind}: off, the page reaches the window's edges", room == (side, 0, 0, 0), room)
            kept = subprocess.run(["defaults", "read", sv.SUITE, "layout.cards"], capture_output=True, text=True).stdout.strip()
            t.ok(f"{kind}: off is kept", kept == "0", kept)
            picture(f"{tag}card-off")

            ui(folded=True)
            room, _ = edges()
            t.ok(f"{kind}: off and folded, the whole window", room == (0, 0, 0, 0), room)
            ui(folded=False)

            ui(cards=True)
            t.ok(f"{kind}: on again, the card where it was", pages() == card, f"{card} -> {pages()}")

            ui(fullscreen=True)
            room, p = edges()
            t.ok(f"{kind}: the window in full screen, no card", p["cards"]["on"] is False and p["cards"]["switch"] is True, p["cards"])
            t.ok(f"{kind}: in full screen, edge to edge", room == (side, 0, 0, 0), room)
            picture(f"{tag}fullscreen")
            ui(folded=True)
            room, _ = edges()
            t.ok(f"{kind}: in full screen and folded, the whole screen", room == (0, 0, 0, 0), room)
            ui(folded=False)
            ui(fullscreen=False)
            room, p = edges()
            t.ok(f"{kind}: out of full screen, the card again", p["cards"]["on"] is True and pages() == card, f"{card} -> {pages()}")
            ends = max(f[2] for f in pages())
            t.ok(f"{kind}: out of full screen, the pages end inside the window", ends <= w, f"{ends} in {w}")

            ui(sidebar=False)
            across = pages()
            ui(cards=False)
            t.ok(f"{kind}: tabs across the top, the switch changes nothing", pages() == across, f"{across} -> {pages()}")
            room, _ = edges()
            t.ok(f"{kind}: tabs across the top, edge to edge on three sides", room[0] == 0 and room[2:] == (0, 0), room)
            sv.quit()
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
