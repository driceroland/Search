#!/usr/bin/env python3
"""Settings › Tabs › Keep the window when its last tab closes (idea 1102),
in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/keep_window_last_tab.py`
from a worktree. ⌘W on the window's last tab, an empty one, closes the
window; with the switch on it leaves the tab, its field emptied, and ⇧⌘W
is how the window goes. A hidden probe has no key window, so the closing
itself can't happen here: what is checked is which way close() went. Off,
what was typed in the field is left as it was (the window was asked to
close, and there is none in front); on, the tab is kept as a new tab, its
field emptied. Also with only pins put down beside it (#1480's case).
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("keep-window-last-tab")


def loose(st):
    return [x["id"] for x in st["tabs"] if x["id"] not in st["pins"]]


def typed():
    return sv.cmd({"do": "sitesearch", "action": "state"})["typed"]


def lone_blank():
    """The window down to one empty tab: every other closed, then a page's
    close leaves the new tab."""
    st = sv.sp("state")
    for id in [x["id"] for x in st["tabs"]][1:]:
        sv.sp("closeTab", id=id)
    st = sv.sp("state")
    if not st["tabs"][0]["blank"]:
        st = sv.sp("closeTab", id=st["tabs"][0]["id"])
    return st


def close_lone_blank(t, on):
    st = lone_blank()
    t.ok("one empty tab in the window", len(st["tabs"]) == 1 and st["tabs"][0]["blank"], st)
    blank = st["activeID"]
    sv.cmd({"do": "field", "text": "abc"})
    t.ok("abc typed in its field", typed() == "abc", typed())
    st = sv.sp("closeTab", id=blank)
    t.ok("the tab is still there", [x["id"] for x in st["tabs"]] == [blank], st)
    if on:
        t.ok("on: kept as a new tab, its field emptied", typed() == "", typed())
    else:
        t.ok("off: the window was asked to close, the field left as it was", typed() == "abc", typed())


def main():
    t = sv.T()
    try:
        sv.setup(); sv.launch()
        close_lone_blank(t, on=False)
        sv.quit(); sv.setup(**{"tabs.keepWindow": True}); sv.launch()
        close_lone_blank(t, on=True)

        # Only pins put down beside it (#1480): the same.
        a = sv.page("a")
        sv.cmd({"do": "pin", "id": a})
        for id in loose(sv.sp("state")):
            sv.sp("closeTab", id=id)
        sv.cmd({"do": "select", "id": a})
        st = sv.sp("closeTab", id=a)
        blank = st["activeID"]
        t.ok("⌘W on the pin puts it down and leaves a new tab", blank != a and blank not in st["pins"], st)
        sv.cmd({"do": "field", "text": "abc"})
        st = sv.sp("closeTab", id=blank)
        t.ok("⌘W on it beside the pin put down keeps it on screen", st["activeID"] == blank, st)
        t.ok("its field emptied", typed() == "", typed())
        time.sleep(0.3)
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
