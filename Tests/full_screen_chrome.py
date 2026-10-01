#!/usr/bin/env python3
"""The column around a page's full screen, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/full_screen_chrome.py`.
Nothing goes full screen: the page's own word that it is going, and that it
is back (Forms.swift, "fullscreen"), is sent from Search's world, and what
lies where the column is is asked of the window. The column steps aside for
the page and comes back after it, with Split View off and on: back
without anything else drawing the window again, as after a video's full
screen ended with Escape, when the column stayed away (reported on 1.0.4). The real full
screen, a video's own, is checked by hand on a release candidate.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402


def immerse(tab, on):
    sv.cmd({"do": "eval", "id": tab, "world": "search",
            "js": f"window.webkit.messageHandlers.officeForms.postMessage({{kind: 'fullscreen', on: {'true' if on else 'false'}}}); 1"})
    time.sleep(1.2)


def under_column():
    return sv.cmd({"do": "hit", "x": 60, "y": 300})["view"]


def main():
    t = sv.T()
    try:
        for split in (False, True):
            name = "Split View on" if split else "Split View off"
            sv.setup(sidebar=True, splitView=split); sv.launch()
            a = sv.page("a"); time.sleep(0.8)
            column = under_column()
            t.ok(f"{name}: the column is there", column not in ("PageView", "StageView"), column)
            immerse(a, True)
            # Going in, the window's own changes draw it again whatever the
            # column does, as a real full screen's do; coming back there
            # may be nothing else, and that was the column left away.
            sv.cmd({"do": "select", "id": a}); time.sleep(0.6)
            t.ok(f"{name}: a page going full screen, the column steps aside", under_column() == "PageView", under_column())
            immerse(a, False)
            t.ok(f"{name}: back from full screen, the column is back", under_column() == column, under_column())
            sv.quit()
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
