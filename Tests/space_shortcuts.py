#!/usr/bin/env python3
"""Space shortcuts through the app's key-event queue, in an isolated hidden run.

Build first with ./build.sh debug, then python3 Tests/space_shortcuts.py.
"""
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv

sv.use("space-shortcuts")


def press(code, chars, mods):
    sv.cmd({"do": "press", "code": code, "chars": chars, "mods": mods})
    time.sleep(0.2)
    return sv.sp("state")["spaceID"]


def run(t, changed, enabled=True):
    sv.setup(spaces=enabled)
    if changed:
        overrides = {
            "spaces.2": {"key": {"key": "2", "command": True, "option": True, "control": False, "shift": False}},
            "spaces.3": {},
        }
        subprocess.run(["defaults", "write", sv.SUITE, "shortcuts", "-data", json.dumps(overrides).encode().hex()], check=True)
    sv.launch()
    try:
        first = sv.sp("state")["spaceID"]
        second = sv.sp("space", spaceAction="new", name="Two")["spaceID"]
        third = sv.sp("space", spaceAction="new", name="Three")["spaceID"]
        sv.sp("space", spaceAction="go", spaceID=first)
        sv.page("shortcut-page")
        expected = second if enabled and not changed else first
        t.ok("Control+2 respects the saved binding", press(19, "2", ["ctrl"]) == expected)
        sv.sp("space", spaceAction="go", spaceID=first)
        expected = second if enabled and changed else first
        t.ok("Option-Command+2 runs only when bound and Spaces enabled", press(19, "2", ["opt", "cmd"]) == expected)
        sv.sp("space", spaceAction="go", spaceID=first)
        expected = third if enabled and not changed else first
        t.ok("a cleared Space key stops switching", press(20, "3", ["ctrl"]) == expected)
        sv.sp("space", spaceAction="go", spaceID=second)
        expected = first if enabled else second
        t.ok("Control+1 reads the physical digit on another layout", press(18, "&", ["ctrl"]) == expected)
        if changed and enabled:
            sv.sp("space", spaceAction="go", spaceID=first)
            sv.quit()
            sv.launch()
            t.ok("the custom key survives relaunch", press(19, "2", ["opt", "cmd"]) == second)
    finally:
        sv.finish()


def main():
    t = sv.T()
    try:
        run(t, False)
        run(t, True)
        run(t, True, enabled=False)
    finally:
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())
