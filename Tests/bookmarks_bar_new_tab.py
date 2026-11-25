#!/usr/bin/env python3
"""Settings › Show the bookmarks bar only on new tabs (idea 1082), in a
hidden probe.

Build first (`./build.sh`), then `python3 Tests/bookmarks_bar_new_tab.py`.
It uses the split suite's harness: started hidden in a world of its own, no
window shown or brought forward, everything removed afterwards.

Off, as it starts: the bar stays above every page. On: the bar is above a
new tab only; a page opened in it takes the bar away, and the page starts
that much higher in the window; going back to a new tab brings it back.
With the bar itself hidden, the setting shows nothing.
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
            sv.cmd({"do": "go", "id": fresh, "url": f"{sv.BASE}/later"}); time.sleep(1.2)
            went = bar()
            t.ok(f"{where}: a page opened in the new tab takes it away", went["barForTab"] is False and went["active"].endswith("/later"), went)
            t.ok(f"{where}: …and the page moves up, as drawn", went["pageTop"] == on["pageTop"], (went["pageTop"], on["pageTop"], blank["pageTop"]))
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
