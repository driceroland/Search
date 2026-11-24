#!/usr/bin/env python3
"""⌘W on the new tab left after putting a pin down (#1480), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/close_blank_beside_pins.py`
from a worktree. With nothing but pins in the space, ⌘W on a pin puts it
down and leaves a new tab; ⌘W on that new tab used to wake the pin just put
down, so ⌘W went pin, new tab, pin, new tab for ever. Now it closes the
window, as it does with Leave a new tab when the last tab closes on (a
hidden probe has no key window, so the new tab is simply still there). With
a pin still open, ⌘T then ⌘W goes back to that pin, as before.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("close-blank-pins")


def active(st):
    return next((x for x in st["tabs"] if x["id"] == st["activeID"]), None)


def loose(st):
    return [x["id"] for x in st["tabs"] if x["id"] not in st["pins"]]


def main():
    t = sv.T()
    try:
        sv.setup(); sv.launch()
        a = sv.page("a")
        sv.cmd({"do": "pin", "id": a})
        for id in loose(sv.sp("state")):
            sv.sp("close", id=id)
        sv.cmd({"do": "select", "id": a})
        st = sv.sp("state")
        t.ok("one pin, on screen, nothing else", st["pins"] == [a] and loose(st) == [] and st["activeID"] == a, st)

        st = sv.sp("closeTab", id=a)
        now = active(st)
        t.ok("⌘W on the pin puts it down and leaves a new tab", now is not None and now["blank"] and now["id"] not in st["pins"], st)
        blank = st["activeID"]

        st = sv.sp("closeTab", id=blank)
        t.ok("⌘W on that new tab doesn't wake the pin just put down", st["activeID"] != a, st)
        a_now = next((x for x in st["tabs"] if x["id"] == a), {})
        t.ok("the pin stays down", a_now.get("asleep") is True, a_now)

        # A pin still open: ⌘T then ⌘W goes back to it, as before.
        sv.cmd({"do": "select", "id": a}); sv.sp("newTab")
        st = sv.sp("state"); fresh = st["activeID"]
        t.ok("⌘T over an open pin gives a new tab", fresh != a and active(st)["blank"], st)
        st = sv.sp("closeTab", id=fresh)
        t.ok("⌘W on it goes back to the open pin", st["activeID"] == a, st)
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
