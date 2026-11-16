#!/usr/bin/env python3
"""The address field from any app (Launcher.swift), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/launcher.py`. It runs in a
world of its own (launcher-tests), started hidden, and everything is removed
afterwards. On a run the bench drives, the key is never asked of macOS and
the panel never shown: the bench works the launcher's model ("fire" is the
key pressed). What only shows on screen — the panel over another app, the
key from there, the click outside — is checked by hand.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("launcher-tests")
t = sv.T()


def la(action="state", **fields):
    return sv.cmd({"do": "launcher", "action": action, **fields})


try:
    sv.setup()
    sv.launch()

    s = la()
    t.ok("off unless turned on, with no key", s["on"] is False and s["key"] == "" and s["wants"] is False, s)
    t.ok("off, the key raises nothing", la("fire")["up"] is False)

    la("on", on=True)
    s = la()
    t.ok("on with no key chosen, no key is taken", s["wants"] is False, s)
    s = la("key", key="suggested")
    t.ok("⇧⌘Space chosen: the key is wanted while Search is behind", s["key"] == "⇧⌘Space" and s["wants"] is True, s)
    t.ok("a run the bench drives never asks macOS for it", s["registered"] is False, s)

    # An ordinary page, then a private one in front.
    plain = sv.page("launcher-plain")
    sv.sp("private")
    time.sleep(0.3)
    sv.sp("open", url=f"{sv.BASE}/launcher-secret")
    time.sleep(0.7)
    s = la()
    secret = [x for x in s["tabs"] if x["address"].endswith("/launcher-secret")]
    t.ok("(the private page is in front)", secret and secret[0]["private"] and s["active"] == secret[0]["id"], s["tabs"])

    s = la("fire")
    t.ok("the key raises the field, empty", s["up"] is True and s["typed"] == "" and s["offers"] == [], s)
    s = la("type", text=f"{sv.BASE}/launcher-new")
    t.ok("the window's own field stays down", s["editing"] is False, s)
    count = len(s["tabs"])
    s = la("submit")
    new = [x for x in s["tabs"] if x["address"].endswith("/launcher-new")]
    t.ok("Return opens what was typed in a new tab, in front", s["up"] is False and len(new) == 1
         and s["active"] == new[0]["id"] and len(s["tabs"]) == count + 1, s)
    t.ok("…an ordinary tab, though a private one was in front", bool(new) and new[0]["private"] is False, new)

    la("fire")
    s = la("type", text="launcher-")
    opened = [o for o in s["offers"] if o["open"]]
    t.ok("a page already open is offered", any(o["url"].endswith("/launcher-plain") for o in opened), s["offers"])
    t.ok("a private tab never is", not any("launcher-secret" in o["url"] for o in s["offers"]), s["offers"])
    pick = next((i for i, o in enumerate(s["offers"]) if o["open"] and o["url"].endswith("/launcher-plain")), None)
    if pick is not None:
        la("pick", index=pick)
    count = len(s["tabs"])
    s = la("submit")
    t.ok("Return on it goes to that tab", s["up"] is False and s["active"] == plain, s)
    t.ok("…with no tab opened for it", len(s["tabs"]) == count, (count, len(s["tabs"])))

    la("fire")
    la("type", text="kept words")
    s = la("escape")
    t.ok("Escape puts it away, nothing opened", s["up"] is False and len(s["tabs"]) == count, s)
    s = la("fire")
    t.ok("…and the words come back with it next time", s["typed"] == "kept words", s)
    t.ok("the key again puts it away", la("fire")["up"] is False)

    la("fire")
    s = la("on", on=False)
    t.ok("turned off while up, it goes and wants no key", s["up"] is False and s["wants"] is False, s)
    la("on", on=True)
    s = la("key", key="none")
    t.ok("the key taken away, none is wanted", s["key"] == "" and s["wants"] is False, s)
finally:
    t.done()
    sv.finish()
sys.exit(1 if t.failed else 0)
