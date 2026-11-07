#!/usr/bin/env python3
"""With Recent places in the new tab on, ⌘T's floating field offers the last
few places from history before anything is typed, never a page already open
and never in a private tab, and Return on the empty field still opens nothing
until an arrow key picks a row. With it off, as it is unless turned on, the
field lists nothing.

Build first (`./build.sh` or `./build.sh debug`), then
`python3 Tests/newtab_recent.py`. It uses the split suite's harness: started
hidden in a world of its own, keys pressed through the app's own event queue.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("newtab-recent")


def cmd_t():
    sv.cmd({"do": "press", "code": 17, "chars": "t", "mods": ["cmd"], "letgo": True})
    time.sleep(0.8)


def bare(code, chars):
    sv.cmd({"do": "press", "code": code, "chars": chars, "mods": []})
    time.sleep(0.8)


def urls():
    return [t.get("url", "") for t in sv.cmd({"do": "tabs"})["tabs"]]


def world():
    b = sv.page("bravo")
    for name in ("echo", "foxtrot", "golf", "hotel", "bravo"):
        sv.cmd({"do": "history", "take": f"{sv.BASE}/{name}"})
        time.sleep(0.05)
    sv.sp("select", id=b); time.sleep(0.5)
    return b


def main():
    t = sv.T()
    try:
        sv.setup(**{"newtab.floating": True})
        sv.launch()
        b = world()
        cmd_t()
        s = sv.cmd({"do": "suggest"})
        t.ok("switch off, as it ships: ⌘T lists nothing", s["editing"] and s["offers"] == [], s["offers"])
        sv.quit()

        sv.setup(**{"newtab.floating": True, "newtab.recent": True})
        sv.launch()
        b = world()
        cmd_t()
        s = sv.cmd({"do": "suggest"})
        offered = [o[2] for o in s["offers"]]
        t.ok("⌘T, nothing typed: three recent places", len(offered) == 3, offered)
        t.ok("newest first, and not Bravo, which is open",
             offered and offered[0].endswith("/hotel") and not any(u.endswith("/bravo") for u in offered), offered)

        count = len(urls())
        bare(36, "\r")
        t.ok("Return with nothing picked opens nothing", len(urls()) == count, urls())

        bare(125, "")
        bare(36, "\r")
        time.sleep(0.8)
        s = sv.cmd({"do": "suggest"})
        t.ok("↓ then Return: the place in a new tab, Bravo still open",
             s["address"].endswith("/hotel") and any(u.endswith("/bravo") for u in urls()), (s["address"], urls()))

        shy = sv.cmd({"do": "open", "url": f"{sv.BASE}/india", "private": True})
        time.sleep(0.8)
        sv.sp("select", id=shy["id"]); time.sleep(0.5)
        cmd_t()
        s = sv.cmd({"do": "suggest"})
        t.ok("from a private tab: nothing offered", s["offers"] == [], s["offers"])
    finally:
        t.done()
        sv.finish()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
