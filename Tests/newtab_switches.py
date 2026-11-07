#!/usr/bin/env python3
"""With Open tabs in the new tab on, ⌘T lists open tabs to switch to: all of
them (most recent first) before anything is typed, and up to two that match
once something is, best match first, in the room of History's places so the
list is no longer. A row says "Open tab", and "↩ Switch" once picked: Return
still opens what was typed unless a tab is picked; ↓ then Return switches;
⌘Return opens a copy behind. An open page's address typed or pasted whole,
tracking tags and all, is picked already. The same in a blank tab's own field
(⌘T without the floating field), whose blank tab goes when it switches away.
Off, as it ships, the field lists no open tab.

Build first (`./build.sh` or `./build.sh debug`), then
`python3 Tests/newtab_switches.py`. It uses the split suite's harness: started
hidden in a world of its own, keys pressed through the app's own event queue.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("newtab-switches")
HOST = sv.BASE.replace("http://", "")


def press(code, chars, mods=("cmd",)):
    sv.cmd({"do": "press", "code": code, "chars": chars, "mods": list(mods), "letgo": True})
    time.sleep(0.8)


def cmd_t():
    press(17, "t")


def bare(code, chars=""):
    sv.cmd({"do": "press", "code": code, "chars": chars, "mods": []})
    time.sleep(0.7)


def typed(text):
    sv.cmd({"do": "field", "text": text})
    time.sleep(0.8)


def state():
    return sv.cmd({"do": "suggest"})


def kinds(s):
    return [o[1] for o in s["offers"]]


def urls():
    return [t.get("url", "") for t in sv.cmd({"do": "tabs"})["tabs"]]


def front():
    return next((t.get("url", "") for t in sv.cmd({"do": "tabs"})["tabs"] if t["active"]), "")


def world():
    a = sv.page("alpha")
    b = sv.page("bravo")
    sv.page("alphabet")
    for name in ("alpha", "alpine", "alps", "alpaca"):
        sv.cmd({"do": "history", "take": f"{sv.BASE}/{name}"})
        time.sleep(0.05)
    sv.sp("select", id=b); time.sleep(0.6)
    return a, b


def away():
    # The field put away by its own key (Escape through the bench's queue
    # doesn't reach the field editor).
    if state()["editing"]:
        cmd_t()


def main():
    t = sv.T()
    try:
        sv.setup(**{"newtab.floating": True})
        sv.launch()
        world()
        cmd_t(); typed("alp")
        t.ok("switch off, as it ships: no open tab in ⌘T's list", "open" not in kinds(state()), kinds(state()))
        away()
        sv.quit()

        sv.setup(**{"newtab.floating": True, "newtab.tabs": True, "commandbar": True})
        sv.launch()
        a, b = world()

        cmd_t()
        s = state()
        t.ok("before typing: the open tabs, not the page under the field, nothing picked",
             s["offers"] and set(kinds(s)) == {"open"} and not any(o[2].endswith("/bravo") for o in s["offers"])
             and s["picked"] == -1, (s["picked"], s["offers"]))
        count = len(urls())
        bare(36, "\r")
        t.ok("Return on the empty field still opens nothing", len(urls()) == count, urls())
        typed("alp")
        s = state()
        k = kinds(s)
        t.ok("two open tabs first, then the places", k[:2] == ["open", "open"], k)
        t.ok("an unpicked open tab says Open tab, no key cap", s["notes"][:2] == ["Open tab", "Open tab"], s["notes"])
        places = [x for x in k if x in ("visited", "bookmark", "known")]
        t.ok("the list is no longer: open tabs and places three at most", k.count("open") + len(places) <= 3, k)
        t.ok("a page open and visited is one row, the open one",
             not any(o[1] == "visited" and o[2].endswith("/alpha") for o in s["offers"]), s["offers"])
        t.ok("nothing picked while typing: Return still opens what was typed", s["picked"] == -1, s["picked"])

        count = len(urls())
        bare(125)
        t.ok("↓ picks it: ↩ Switch", state()["notes"][0] == "↩ Switch", state()["notes"])
        bare(36, "\r"); time.sleep(0.8)
        t.ok("↓ then Return switches: no new tab, an open page in front, field gone",
             len(urls()) == count and front().split("/")[-1] in ("alpha", "alphabet") and not state()["editing"],
             (urls(), front()))

        sv.sp("select", id=b); time.sleep(0.6)
        cmd_t(); typed("alp"); bare(125)
        count = len(urls())
        press(36, "\r", ("cmd",)); time.sleep(0.8)
        t.ok("↓ then ⌘Return: a copy behind, Bravo still in front",
             len(urls()) == count + 1 and front().endswith("/bravo"), (urls(), front()))

        sv.sp("select", id=b); time.sleep(0.6)
        cmd_t(); typed(f"http://{HOST}/alpha?utm_source=newsletter&fbclid=IwAR2xYz")
        s = state()
        t.ok("Alpha's address pasted with tracking tags: Alpha's tab, picked",
             s["offers"] and s["offers"][0][1] == "open" and s["offers"][0][2].endswith("/alpha") and s["picked"] == 0,
             (s["picked"], s["offers"]))
        count = len(urls())
        bare(36, "\r"); time.sleep(0.8)
        t.ok("Return goes to the open Alpha, no second copy",
             len(urls()) == count and front().endswith("/alpha"), (urls(), front()))

        sv.sp("select", id=b); time.sleep(0.6)
        extra = [sv.page(n) for n in ("alpaca", "alps")]
        sv.cmd({"do": "history", "take": f"{sv.BASE}/alpaca"})
        twice = sv.page("alpha"); sv.sp("select", id=b); time.sleep(0.6)
        cmd_t(); typed("alp")
        s = state()
        opened = {u for u in urls()}
        t.ok("past the first two, an open page isn't offered as a place to open again",
             not any(o[1] in ("visited", "bookmark", "known") and o[2] in opened for o in s["offers"]), s["offers"])
        rows = [o[2] for o in s["offers"] if o[1] == "open"]
        t.ok("a page open twice is one row", len(rows) == len(set(rows)), rows)
        away()
        for x in extra + [twice]: sv.sp("close", id=x)
        sv.sp("select", id=b); time.sleep(0.6)
        cmd_t(); typed(f"http://{HOST}/alpha#part-two")
        s = state()
        t.ok("a link to a #section of an open page: offered, not picked (switching wouldn't go there)",
             s["offers"] and s["offers"][0][1] == "open" and s["picked"] == -1, (s["picked"], s["offers"]))
        away()

        older = sv.page("pinecone"); newer = sv.page("alpine-lodge"); sv.sp("select", id=b); time.sleep(0.6)
        cmd_t(); typed("pine")
        rows = [o[2] for o in state()["offers"] if o[1] == "open"]
        t.ok("a title that starts with the words beats a newer one that only contains them",
             rows and rows[0].endswith("/pinecone"), rows)
        away()
        for x in (older, newer): sv.sp("close", id=x)
        sv.sp("select", id=b); time.sleep(0.6)

        cmd_t(); typed("bravo")
        t.ok("the page the field is over isn't offered", "open" not in kinds(state()), state()["offers"])
        away()

        sv.page("settings-notes"); sv.sp("select", id=b); time.sleep(0.6)
        cmd_t(); typed("settings")
        k = kinds(state())
        t.ok("a command stays first, over an open tab that matches (Return runs it)",
             k[:2] == ["command", "open"], k)
        away()

        press(40, "k"); typed(f"http://{HOST}/alpha?utm_source=x")
        s = state()
        t.ok("⌘K: a pasted address of an open tab finds the tab",
             s["offers"] and s["offers"][0][1] == "open", s["offers"])
        press(40, "k")
        sv.quit()

        # ⌘T without the floating field: a blank tab, whose own field lists them.
        sv.setup(**{"newtab.tabs": True})
        sv.launch()
        a, b = world()
        before = urls()
        cmd_t()
        s = state()
        t.ok("blank tab from ⌘T: its field lists the open tabs", s["offers"] and set(kinds(s)) == {"open"}, s["offers"])
        typed("alp"); bare(125)
        t.ok("…and as you type, ↩ Switch once picked", state()["notes"][0] == "↩ Switch", state()["notes"])
        bare(36, "\r"); time.sleep(0.8)
        pages = [u for u in urls() if u]
        t.ok("switching away doesn't leave the blank tab behind, and opens nothing",
             "" not in urls() and len(pages) == len([u for u in before if u])
             and front().split("/")[-1].startswith("alp"), (urls(), front()))
        count = len(urls())
        cmd_t(); typed("alp"); bare(125)
        press(36, "\r", ("cmd",)); time.sleep(0.8)
        t.ok("⌘Return from the blank tab: a copy behind, the blank tab still there to type in",
             len(urls()) == count + 2 and "" in urls(), urls())
    finally:
        t.done()
        sv.finish()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
