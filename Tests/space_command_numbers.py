#!/usr/bin/env python3
"""⌘1–⌘9 switch spaces and ⌃1–⌃9 pick tabs, with Settings › Spaces & Pins'
switch on (as in Arc), through the app's key-event queue in a hidden probe.

Build first with ./build.sh debug, then python3 Tests/space_command_numbers.py.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv

sv.use("space-command-numbers")

ONE, TWO, THREE = 18, 19, 20


def press(code, chars, mods):
    sv.cmd({"do": "press", "code": code, "chars": chars, "mods": mods})
    time.sleep(0.2)
    return sv.sp("state")


def run(t, swapped):
    sv.setup(**{"spaces": True, "spaces.commandNumbers": swapped})
    sv.launch()
    try:
        first = sv.sp("state")["spaceID"]
        second = sv.sp("space", spaceAction="new", name="Two")["spaceID"]
        sv.sp("space", spaceAction="go", spaceID=first)
        for name in ["one", "two", "three"]:
            sv.page(f"numbers-{name}")
        tabs = sv.order(sv.sp("state"))
        label = "swapped" if swapped else "as usual"
        # The tab key: ⌃2 swapped, ⌘2 as usual.
        state = press(TWO, "2", ["ctrl"] if swapped else ["cmd"])
        t.ok(f"{label}: the tab key picks the second tab", state["activeID"] == tabs[1] and state["spaceID"] == first,
             f"{state['activeID']} {tabs}")
        # The space key: ⌘2 swapped, ⌃2 as usual.
        state = press(TWO, "2", ["cmd"] if swapped else ["ctrl"])
        t.ok(f"{label}: the space key goes to the second space", state["spaceID"] == second)
        state = press(ONE, "&", ["cmd"] if swapped else ["ctrl"])
        t.ok(f"{label}: the space key reads the physical digit", state["spaceID"] == first)
        state = press(THREE, "3", ["ctrl"] if swapped else ["cmd"])
        t.ok(f"{label}: the third tab, back in the first space", state["activeID"] == tabs[2] and state["spaceID"] == first)
        if swapped:
            # The switch off again, live: ⌘ back to the tabs, ⌃ to the spaces.
            sv.cmd({"do": "ui", "spacesOnCommand": False})
            state = press(TWO, "2", ["cmd"])
            t.ok("switched off live: ⌘2 picks a tab again", state["activeID"] == tabs[1] and state["spaceID"] == first)
            state = press(TWO, "2", ["ctrl"])
            t.ok("switched off live: ⌃2 goes to the second space", state["spaceID"] == second)
    finally:
        sv.finish()


def main():
    t = sv.T()
    try:
        run(t, False)
        run(t, True)
    finally:
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())
