#!/usr/bin/env python3
"""Words typed into ⌘K that no open page answers to go to a new tab, offered as
a row of their own, and an empty switcher says why it is empty.

Build first (`./build.sh` or `./build.sh debug`), then
`python3 Tests/switcher_address.py`. It uses the split suite's harness:
started hidden in a world of its own, keys pressed through the app's own
event queue.

Reported as: ⌘K over a page, an address typed, Return: the page ⌘K was
pressed over was replaced, where ⌘T's field, which looks the same, opens a
new tab. ⌘T, then ⌘K, did the same.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("switcher-address")
KEYS = {"t": 17, "k": 40}
HOST = sv.BASE.replace("http://", "")


def press(key):
    sv.cmd({"do": "press", "code": KEYS[key], "chars": key, "mods": ["cmd"], "letgo": True})
    time.sleep(0.6)


def enter():
    sv.cmd({"do": "press", "code": 36, "chars": "\r", "mods": []})
    time.sleep(1.2)


def typed(text):
    sv.cmd({"do": "field", "text": text})
    time.sleep(0.4)
    return sv.cmd({"do": "suggest"})


def urls():
    return [t.get("url", "") for t in sv.cmd({"do": "tabs"})["tabs"]]


def front():
    return sv.cmd({"do": "suggest"})["address"]


def main():
    t = sv.T()
    try:
        sv.setup(**{"newtab.floating": True})
        sv.launch()
        a, b = sv.page("alpha"), sv.page("bravo")

        # On a blank tab there is nothing to keep: the blank takes the address.
        blank = next(x["id"] for x in sv.cmd({"do": "tabs"})["tabs"] if not x.get("url"))
        sv.sp("select", id=blank); time.sleep(0.5)
        count = len(urls())
        press("k")
        typed(f"{HOST}/foxtrot")
        enter()
        t.ok("⌘K on a blank tab: the address goes into that tab, no new one",
             front().endswith("/foxtrot") and len(urls()) == count, urls())

        sv.sp("select", id=b); time.sleep(0.5)
        press("k")
        s = typed(f"{HOST}/delta")
        last = s["offers"][-1] if s["offers"] else None
        t.ok("⌘K, an address no tab has: offered as its own row, in a new tab",
             last and last[0] == f"{HOST}/delta" and last[2].endswith("/delta"), s["offers"])
        enter()
        t.ok("Return opens it in a new tab and Bravo stays",
             front().endswith("/delta") and any(u.endswith("/bravo") for u in urls()), urls())

        sv.sp("select", id=b); time.sleep(0.5)
        press("t")
        typed(f"{HOST}/echo")
        press("k")
        typed(f"{HOST}/echo")
        enter()
        t.ok("⌘T, then ⌘K, then Return: still a new tab, Bravo stays",
             front().endswith("/echo") and any(u.endswith("/bravo") for u in urls()), urls())

        sv.sp("select", id=b); time.sleep(0.5)
        press("k")
        s = typed("alpha")
        t.ok("words an open tab answers to: that tab first, the new tab last",
             s["offers"][0][1] == "open" and s["offers"][-1][0] == "alpha", s["offers"])
        enter()
        t.ok("and Return switches to it", front().endswith("/alpha"), front())

        # Nothing else open: the switcher says so.
        for tab in sv.cmd({"do": "tabs"})["tabs"]:
            if not tab.get("url", "").endswith("/alpha"):
                sv.sp("close", id=tab["id"])
        sv.sp("select", id=a); time.sleep(0.6)
        press("k")
        s = sv.cmd({"do": "suggest"})
        t.ok("⌘K with no other tab: 'No other tabs open'", s["note"] == "No other tabs open", s)
    finally:
        t.done()
        sv.finish()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
