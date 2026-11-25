#!/usr/bin/env python3
"""Idea 1099: the field ⌘T or ⌘L raises still has the keys a second later,
long after its open animation, and what is typed then goes in.

Build first (`./build.sh`), then `python3 Tests/field_keeps_keys.py`. Hidden
probe in a world of its own (the split suite's harness); no window shown.

As the open animation ends, SwiftUI moves the field out of the view it drew
it in during the animation, within the same window. macOS 27 ends the
field's editing in that move and leaves the keys with the window; the macOS
this may run on keeps them. So each case runs twice: as this Mac does it,
and with the move made to drop the keys as macOS 27 does
(test.fieldDropsKeysOnMove, read only in a test run). Floating field on and
off, the field in the middle of the window, Reduce animations on and off.

Idea 1061 too: what was typed in ⌘T's field and put away comes back
selected, so the next key types over it.
"""
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("field-keeps-keys")
t = sv.T()
CODES = {"a": 0, "b": 11, "c": 8, "x": 7, "y": 16, "z": 6}


def press(code, chars, cmd=False):
    return sv.cmd({"do": "press", "code": code, "chars": chars, "mods": ["cmd"] if cmd else []})


def type_(text):
    for c in text: press(CODES[c], c)


def where():
    p = sv.cmd({"do": "probe"})
    return p["responderIsAddress"], p.get("pageActivity", {}).get("windowResponder", ""), p.get("fieldText", "")


def escape(tab):
    press(53, "\x1b"); time.sleep(0.5)
    a = press(63, "").get("active", "")
    if a and not tab.startswith(a):
        press(13, "w", cmd=True); time.sleep(0.6)


def write(key, on):
    subprocess.run(["defaults", "write", sv.SUITE, key, "-bool", "true" if on else "false"])


try:
    for drop in (False, True):
        for instant in (False, True):
            for floating, centred in ((True, False), (True, True), (False, False)):
                sv.setup()
                write("newtab.floating", floating); write("field.window", centred)
                write("motion.instant", instant); write("test.fieldDropsKeysOnMove", drop)
                sv.launch()
                tab = sv.sp("open", url=f"{sv.BASE}/plain")["resultID"]; time.sleep(1.5)
                mode = ("floating" if floating else "plain") + (", centred" if centred else "") \
                    + (", reduce animations" if instant else "") + (", move drops the keys" if drop else "")
                for name, code, chars in (("⌘T", 17, "t"), ("⌘L", 37, "l")):
                    press(code, chars, cmd=True)
                    seen, start = [], time.time()
                    for at in (0.05, 0.2, 0.4, 0.6, 1.0):
                        while time.time() - start < at: time.sleep(0.01)
                        seen.append(where())
                    type_("xyz"); time.sleep(0.3)
                    text = where()[2]
                    print(f"   {mode} {name}: " + " ".join("F" if s[0] else (s[1] or "-") for s in seen) + f" text={text!r}")
                    t.ok(f"{mode}: {name}, the field has the keys 1 s later", seen[-1][0], f"{seen}")
                    t.ok(f"{mode}: {name}, typing 1 s later goes in", text.startswith("xyz"), f"text={text!r}")
                    escape(tab)
                if floating:
                    # Idea 1061: a draft put away comes back selected.
                    press(17, "t", cmd=True); time.sleep(0.8); type_("abc"); time.sleep(0.2)
                    escape(tab)
                    press(17, "t", cmd=True); time.sleep(1.0)
                    back = where()[2]
                    type_("x"); time.sleep(0.3)
                    text = where()[2]
                    t.ok(f"{mode}: ⌘T's draft comes back, and the next key types over it",
                         back.startswith("abc") and text.startswith("x") and "abc" not in text, f"back={back!r} then={text!r}")
                    escape(tab)
                sv.finish()
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
