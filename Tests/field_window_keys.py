#!/usr/bin/env python3
"""Idea 1033: with Settings › The field in the middle of the window on, ⌘T's
floating field and ⌘L's field over a page have the keys, as they do off.

Build first (`./build.sh`), then `python3 Tests/field_window_keys.py`. It
uses the split suite's harness: started hidden in a world of its own, no
window shown, everything removed afterwards.

The page's pane made a field of its own a moment after the window's, which
took the keys and went with them, leaving them to the window: typing did
nothing until the field was clicked. Read through the bench's `probe`
(what has the keys) and `caret` (a field being typed in).
"""
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("field-window-keys")
t = sv.T()


def typing():
    try:
        sv.cmd({"do": "caret"})
        return sv.cmd({"do": "probe"}).get("responder") == "NSTextView"
    except RuntimeError:
        return False


def press(code, chars):
    sv.cmd({"do": "press", "code": code, "chars": chars, "mods": ["cmd"]}); time.sleep(0.8)


def escape():
    sv.cmd({"do": "press", "code": 53, "chars": "\u001b"}); time.sleep(0.6)


try:
    for centred in (False, True):
        sv.setup(sidebar=True)
        subprocess.run(["defaults", "write", sv.SUITE, "newtab.floating", "-bool", "true"])
        subprocess.run(["defaults", "write", sv.SUITE, "field.window", "-bool", "true" if centred else "false"])
        sv.launch()
        sv.page("one"); time.sleep(1.5)
        where = "in the middle of the window" if centred else "over the page"
        for n in (1, 2):
            press(17, "t")
            t.ok(f"field {where}: ⌘T's field has the keys ({n})", typing())
            escape()
        press(37, "l")
        t.ok(f"field {where}: ⌘L's field has the keys", typing())
        escape()
        sv.finish()
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
