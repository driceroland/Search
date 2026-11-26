#!/usr/bin/env python3
"""⌘W on a new tab with a pin put down and a tab asleep beside it (#1656),
in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/close_blank_beside_sleeping.py`
from a worktree. A pin was read and put down; the only other tab was put to
sleep for not being looked at. ⌘T, then ⌘W on that new tab landed on the
tab viewed before it, the pin put down, and woke it; ⌘W on the pin left a
new tab again, for ever. It lands on the sleeping tab now, as Expected in
the report; the pin stays down.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("close-blank-sleeping")


def tab(st, id):
    return next((x for x in st["tabs"] if x["id"] == id), {})


def run(t, goes_back):
        w = "back" if goes_back else "neighbour"
        sv.setup(**{"tabs.closeGoesBack": goes_back}); sv.launch()
        a = sv.page("a")
        b = sv.page("b")
        sv.cmd({"do": "pin", "id": a})
        st = sv.sp("state")
        for x in st["tabs"]:
            if x["id"] not in (a, b) and x["id"] not in st["pins"]:
                sv.sp("close", id=x["id"])
        # b, read a while ago and put to sleep, as the browser does.
        sv.cmd({"do": "select", "id": b}); time.sleep(0.4)
        sv.cmd({"do": "select", "id": a}); time.sleep(0.4)
        sv.sp("age", id=b, seconds=3600)
        r = sv.sp("sleep", id=b); time.sleep(0.4)
        st = sv.sp("state")
        t.ok(f"{w}: b is asleep, a is on screen", tab(st, b).get("asleep") is True and st["activeID"] == a, (r, st))
        # The pin put down: ⌘W on it lands on a new tab or on b.
        st = sv.sp("closeTab", id=a); time.sleep(0.4)
        t.ok(f"{w}: ⌘W puts the pin down", tab(st, a).get("asleep") is True, st)
        sv.sp("newTab"); time.sleep(0.4)
        st = sv.sp("state"); blank = st["activeID"]
        t.ok(f"{w}: ⌘T gives a new tab", blank not in (a, b), st)
        st = sv.sp("closeTab", id=blank); time.sleep(0.4)
        t.ok(f"{w}: ⌘W on it doesn't land on the pin put down", st["activeID"] != a, st)
        t.ok(f"{w}: the pin stays down", tab(st, a).get("asleep") is True, tab(st, a))
        t.ok(f"{w}: it lands on the sleeping tab", st["activeID"] == b, st["activeID"])
        sv.quit()


def main():
    t = sv.T()
    try:
        for goes_back in (False, True):
            run(t, goes_back)
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
