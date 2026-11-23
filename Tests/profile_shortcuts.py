#!/usr/bin/env python3
"""Keys for profiles (#1437): Next Profile, Previous Profile and Profile 1–9
in Settings › Shortcuts, no key until you give one.

Build first (`./build.sh`), then `python3 Tests/profile_shortcuts.py`. In a
hidden probe with Spaces and Profiles in one window on, two more profiles
are made, keys are given in the saved shortcuts, and pressed through the
app's own key queue: Profile 2 goes to the second, Next goes round from the
last to the first, Previous back again, Profile 9 (no ninth) does nothing.
The app stays hidden throughout; each key goes to the window on screen.
"""
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("sp-profile-shortcuts")


def key(digit):
    return {"key": {"key": str(digit), "command": True, "option": True, "control": False, "shift": False}}


CODES = {1: 18, 2: 19, 3: 20, 4: 21, 9: 25}


def shown():
    """The window on screen, the others tucked behind it (OneWindow.swift):
    its number for the bench and its profile's name."""
    ws = [w for w in sv.cmd({"do": "windows"})["windows"] if w["open"] and not w["tucked"]]
    return (ws[0]["n"], ws[0]["profile"]) if len(ws) == 1 else (1, "several: " + str([w["profile"] for w in ws]))


def press(digit):
    """The key pressed in the window on screen, as a person would."""
    sv.cmd({"do": "press", "code": CODES[digit], "chars": str(digit), "mods": ["opt", "cmd"], "window": shown()[0]})
    time.sleep(1.2)
    return shown()[1]


def main():
    t = sv.T()
    try:
        sv.setup(spaces=True, **{"profiles.oneWindow": True})
        overrides = {"profiles.1": key(1), "profiles.2": key(2), "profiles.next": key(3),
                     "profiles.previous": key(4), "profiles.9": key(9)}
        subprocess.run(["defaults", "write", sv.SUITE, "shortcuts", "-data", json.dumps(overrides).encode().hex()], check=True)
        sv.launch()
        t.ok("one profile: Profile 2's key does nothing", press(2) == "Personal")
        for name in ("Work", "School"):
            sv.cmd({"do": "profile", "action": "new", "name": name})
            time.sleep(0.6)
        names = [p["name"] for p in sv.cmd({"do": "profile"})["profiles"]]
        t.ok("three profiles", names == ["Personal", "Work", "School"], names)
        t.ok("Profile 2 brings Work", press(2) == "Work")
        t.ok("Next Profile brings School", press(3) == "School")
        t.ok("Next Profile from the last goes round to Personal", press(3) == "Personal")
        t.ok("Previous Profile from the first goes round to School", press(4) == "School")
        t.ok("Profile 9, with no ninth, stays", press(9) == "School")
        t.ok("Profile 1 brings Personal", press(1) == "Personal")
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


main()
