#!/usr/bin/env python3
"""Escape on a new tab: the text first, then the tab (Varun, 1.0.6).

Build first (`./build.sh`), then `python3 Tests/new_tab_escape.py`. Keys are
pressed through the app, so the window's key monitor sees them as it sees a
hand's, in a hidden probe:

- ⌘T from a page, a word typed, Escape: the word goes and the new tab
  stays; Escape again: the unused tab closes and the page is back in front;
- ⌘T and Escape with nothing typed closes it at once, as in 1.0.5;
- the only tab, empty, with a word typed: Escape clears the word, and the
  next Escape leaves the tab (closing it would close the window).

Nothing here makes, shows or brings forward a window.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bld-va2-esc")

CMD_T, ESC = 17, 53
LETTERS = {"h": 4, "e": 14, "l": 37, "o": 31}


def press(code, chars, mods=()):
    return sv.cmd({"do": "press", "code": code, "chars": chars, "mods": list(mods)})


def typed(): return sv.cmd({"do": "sitesearch", "action": "state"})["typed"]


def front():
    st = sv.sp("state")
    return next((x for x in st["tabs"] if x["id"] == st["activeID"]), None), st


def word(text="hello"):
    for ch in text:
        press(LETTERS[ch], ch)
    time.sleep(0.3)


def main():
    t = sv.T()
    try:
        sv.setup(**{"start.fresh": False})
        sv.launch()
        a = sv.page("alpha")
        for x in sv.sp("state")["tabs"]:
            if x.get("blank"):
                sv.sp("close", id=x["id"]); time.sleep(0.3)
        sv.sp("select", id=a); time.sleep(0.4)
        count = len(sv.sp("state")["tabs"])

        press(CMD_T, "t", ["cmd"]); time.sleep(0.5)
        word()
        f, st = front()
        t.ok("⌘T and a word: a new tab with the word typed", f and f.get("blank") and typed() == "hello", (f, typed()))
        press(ESC, "\x1b"); time.sleep(0.4)
        f, st = front()
        t.ok("first Escape clears the word", typed() == "", typed())
        t.ok("and the new tab stays in front", f and f.get("blank") and len(st["tabs"]) == count + 1, (f, len(st["tabs"])))
        press(ESC, "\x1b"); time.sleep(0.5)
        f, st = front()
        t.ok("second Escape closes the unused tab", len(st["tabs"]) == count, len(st["tabs"]))
        t.ok("and the page is back in front", f and f["id"] == a, f)

        press(CMD_T, "t", ["cmd"]); time.sleep(0.5)
        f, st = front()
        t.ok("⌘T again: a new tab", f and f.get("blank") and len(st["tabs"]) == count + 1, f)
        press(ESC, "\x1b"); time.sleep(0.5)
        f, st = front()
        t.ok("nothing typed: one Escape closes it", len(st["tabs"]) == count and f and f["id"] == a, (f, len(st["tabs"])))

        # The only tab, empty.
        press(CMD_T, "t", ["cmd"]); time.sleep(0.5)
        sv.sp("close", id=a); time.sleep(0.5)
        f, st = front()
        t.ok("the only tab is an empty one", len(st["tabs"]) == 1 and f and f.get("blank"), st["tabs"])
        press(CMD_T, "t", ["cmd"]); time.sleep(0.4)
        word("hel")
        t.ok("a word typed in it", typed() == "hel", typed())
        press(ESC, "\x1b"); time.sleep(0.4)
        f, st = front()
        t.ok("Escape clears it, the tab stays", typed() == "" and len(st["tabs"]) == 1 and f.get("blank"), (typed(), st["tabs"]))
        press(ESC, "\x1b"); time.sleep(0.4)
        f, st = front()
        t.ok("Escape again leaves the only tab", len(st["tabs"]) == 1 and f and f.get("blank"), st["tabs"])
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
