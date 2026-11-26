#!/usr/bin/env python3
"""Settings › Show the bookmarks bar only on new tabs (idea 1082), in a
hidden probe.

Build first (`./build.sh`), then `python3 Tests/bookmarks_bar_new_tab.py`.
It uses the split suite's harness: started hidden in a world of its own, no
window shown or brought forward, everything removed afterwards.

Off, as it starts: the bar stays above every page. On: the bar is above a
new tab only; a page opened in it takes the bar away, and the page starts
that much higher in the window; going back to a new tab brings it back.
With the bar itself hidden, the setting shows nothing. With the tabs down
a side folded away (or peeking), a new tab keeps its bar (#1625).
"""
import json
import os
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bookmarks-bar-new-tab")


def mark(title, url):
    return {"id": str(uuid.uuid4()).upper(), "title": title, "url": url}


def bar(**f):
    time.sleep(0.4)
    return sv.cmd({"do": "bar", **f})


def main():
    t = sv.T()
    try:
        for sidebar in (False, True):
            where = "column" if sidebar else "top row"
            sv.setup(sidebar=sidebar, **{"bookmarks.bar": True})
            os.makedirs(sv.SUPPORT, exist_ok=True)
            json.dump([mark("Alpha", f"{sv.BASE}/a")], open(f"{sv.SUPPORT}/bookmarks.json", "w"))
            sv.launch()
            page = sv.page("page")
            off = bar()
            t.ok(f"{where}: off by default, the bar is above a page", off["barForTab"] is True, off)
            on = bar(newTabOnly=True)
            t.ok(f"{where}: on, no bar above a page", on["barForTab"] is False, on)
            t.ok(f"{where}: …and the page starts higher by the bar's height",
                 on["pageTop"] >= 0 and off["pageTop"] - on["pageTop"] >= 20, (off["pageTop"], on["pageTop"]))
            sv.sp("newTab"); time.sleep(0.6)
            blank = bar()
            fresh = next(x["id"] for x in sv.cmd({"do": "tabs"})["tabs"] if x.get("active"))
            t.ok(f"{where}: a new tab has the bar", blank["barForTab"] is True and blank["active"] == "", blank)

            sv.cmd({"do": "ui", "folded": True})
            kept = bar()
            t.ok(f"{where}: folded away, a new tab keeps its bar in the column layout only", kept["barForTab"] is sidebar, kept)
            if sidebar:
                frame = kept["frames"][0]
                t.ok("column: the folded bar is drawn across the room that opens up",
                     frame[2] > 0 and frame[0] < blank["frames"][0][0] - 30, (frame, blank["frames"][0]))
                sv.cmd({"do": "ui", "peek": True})
                peeking = bar()
                t.ok("column: an edge peek leaves the new tab's bar in place",
                     peeking["barForTab"] is True and peeking["frames"][0] == frame, peeking)
                sv.cmd({"do": "ui", "peek": False})
                sv.cmd({"do": "ui", "hides": True})
                auto = bar()
                t.ok("column: the bar clears the auto-hidden sidebar's edge",
                     auto["barForTab"] is True and auto["frames"][0][0] >= frame[0] + 20, auto)
                sv.cmd({"do": "ui", "hides": False})
                time.sleep(0.5)
                sv.cmd({"do": "ui", "folded": True})

            sv.cmd({"do": "go", "id": fresh, "url": f"{sv.BASE}/later"}); time.sleep(1.2)
            went = bar()
            t.ok(f"{where}: a page opened in the folded new tab has no bar",
                 went["barForTab"] is False and went["active"].endswith("/later"), went)
            always = bar(newTabOnly=False)
            t.ok(f"{where}: with the bar on every page, folding still takes it away", always["barForTab"] is False, always)
            sv.cmd({"do": "ui", "folded": False})
            unfolded = bar(newTabOnly=True)
            t.ok(f"{where}: the page starts at the same height as before",
                 unfolded["pageTop"] == on["pageTop"], (unfolded["pageTop"], on["pageTop"]))
            sv.sp("select", id=page); time.sleep(0.4)
            back = bar(newTabOnly=False)
            t.ok(f"{where}: switched off again, the bar is back above the page", back["barForTab"] is True and back["pageTop"] == off["pageTop"], back)
            sv.quit()
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
