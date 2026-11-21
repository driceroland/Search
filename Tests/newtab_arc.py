#!/usr/bin/env python3
"""With Arc-style tab popup on, ⌘T's floating field lists the open tabs that
match what is typed, then the pins, then the places a new tab would go, and
picks the best of them as you type: an open tab, else a pin, else nothing
of its own, leaving history's completion as it was. Return switches to the
picked tab, and the field keeps what was typed, with the rest of the tab's
address after it only when what was typed starts it. One letter counts only
at the start of a word. ↑ lets go of the tab. With the switch off, as it
ships, the field lists no open tab.

Build first (`./build.sh` or `./build.sh debug`), then
`python3 Tests/newtab_arc.py`. It uses the split suite's harness: started
hidden in a world of its own, keys pressed through the app's own event queue.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("newtab-arc")


def cmd_t():
    sv.cmd({"do": "press", "code": 17, "chars": "t", "mods": ["cmd"], "letgo": True})
    time.sleep(0.8)


def type_in(text):
    sv.cmd({"do": "field", "text": text, "type": True})
    time.sleep(0.6)
    return sv.cmd({"do": "suggest"})


def go():
    return sv.cmd({"do": "suggest", "action": "go"})


def esc():
    sv.cmd({"do": "suggest", "action": "esc"})
    time.sleep(0.4)


def urls():
    return [t.get("url", "") for t in sv.cmd({"do": "tabs"})["tabs"]]


def world():
    sv.page("kettle")
    pin = sv.page("kettle-pin")
    sv.cmd({"do": "pin", "id": pin})
    b = sv.page("bravo")
    sv.sp("select", id=b); time.sleep(0.5)
    return b


def main():
    t = sv.T()
    try:
        sv.setup(**{"newtab.floating": True})
        sv.launch()
        world()
        cmd_t()
        s = type_in("kett")
        t.ok("switch off, as it ships: no open tab listed", not any(o[1] == "open" for o in s["offers"]), s["offers"])
        esc()
        sv.quit()

        sv.setup(**{"newtab.floating": True, "newtab.arc": True})
        sv.launch()
        b = world()
        cmd_t()
        s = type_in("kett")
        rows = [(o[1], o[2].rsplit("/", 1)[-1]) for o in s["offers"]]
        t.ok("the open tab first, then the pin", rows[:2] == [("open", "kettle"), ("open", "kettle-pin")], rows)
        t.ok("neither listed again as a place to load",
             not any(o[1] != "open" and o[2].rsplit("/", 1)[-1] in ("kettle", "kettle-pin") for o in s["offers"]), rows)
        t.ok("the open tab is picked as you type", s["picked"] == 0, s["picked"])
        t.ok("and the field keeps what was typed", s["completed"] == "kett", s["completed"])

        count = len(urls())
        s = go()
        t.ok("Return switches to it, with no new tab",
             s["address"].endswith("/kettle") and len(urls()) == count, (s["address"], urls()))

        sv.sp("select", id=b); time.sleep(0.5)
        cmd_t()
        s = type_in("ttle")
        t.ok("words inside a name: listed and picked", s["picked"] == 0 and s["offers"][0][1] == "open", (s["picked"], s["offers"][:2]))
        esc()

        cmd_t()
        s = type_in("127")
        t.ok("the start of its address: the rest follows in grey",
             s["picked"] == 0 and s["completed"].startswith("127") and s["completed"].endswith("/kettle"), (s["picked"], s["completed"]))
        esc()

        cmd_t()
        s = type_in("t")
        t.ok("one letter inside a word lists no tab", not any(o[1] == "open" for o in s["offers"]), s["offers"])
        esc()

        cmd_t()
        s = type_in("pin")
        t.ok("no open tab answers: the pin is picked",
             s["picked"] == 0 and s["offers"][0][2].endswith("/kettle-pin"), (s["picked"], s["offers"][:2]))
        s = go()
        t.ok("Return goes to the pin", s["address"].endswith("/kettle-pin"), s["address"])

        sv.sp("select", id=b); time.sleep(0.5)
        cmd_t()
        s = type_in("kett")
        s = sv.cmd({"do": "suggest", "action": "walk", "step": -1})
        t.ok("↑ lets go of the tab", s["picked"] == -1 and s["completed"] == "kett", (s["picked"], s["completed"]))
        count = len(urls())
        s = go()
        time.sleep(0.5)
        t.ok("then Return opens a new tab", len(urls()) == count + 1, urls())
    finally:
        t.done()
        sv.finish()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
