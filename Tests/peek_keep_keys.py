#!/usr/bin/env python3
"""⌘O keeps a peek as a tab, as it keeps a small window (Little.swift), in a
hidden probe.

Build first (`./build.sh debug`), then `python3 Tests/peek_keep_keys.py`. It
uses the split suite's harness in a world of its own (peek-keep-keys): started
hidden, everything removed afterwards.

⌘O and ⌘Return both put the peek's page in the row, beside the tab it was
opened from, and in front. Plain O, or ⌘⇧O, leaves the peek where it is.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("peek-keep-keys")
t = sv.T()


def probe(): return sv.cmd({"do": "probe"})
def tabs(): return sv.cmd({"do": "tabs"})["tabs"]
def press(code, chars, *mods):
    active = sv.cmd({"do": "press", "code": code, "chars": chars, "mods": list(mods)}).get("active", "")
    time.sleep(0.4)
    return active


def until(check, seconds=4):
    for _ in range(int(seconds * 10)):
        if check(): return True
        time.sleep(0.1)
    return False


def a_peek(name):
    under = sv.cmd({"do": "open", "url": f"{sv.BASE}/under-{name}"})["id"]
    time.sleep(0.8)
    sv.cmd({"do": "select", "id": under}); time.sleep(0.4)
    sv.cmd({"do": "peek", "url": f"{sv.BASE}/peeked-{name}"})
    until(lambda: probe()["peekShown"] and probe()["peek"].endswith(f"/peeked-{name}"))
    return under


def kept(name):
    st = probe()
    in_row = [x for x in tabs() if x.get("url", "").endswith(f"/peeked-{name}")]
    return not st["peekShown"] and st["peekFrom"] == "" and len(in_row) == 1, (st["peekFrom"], in_row)


def front(active, name):
    return bool(active) and any(x["id"] == active and x.get("url", "").endswith(f"/peeked-{name}") for x in tabs())


try:
    sv.setup(); sv.launch()

    a_peek("o")
    active = press(31, "o", "cmd")
    ok, seen = kept("o")
    t.ok("⌘O: the peek goes into the row", ok, seen)
    t.ok("⌘O: and is the tab in front", front(active, "o"), active)

    a_peek("return")
    press(36, "\r", "cmd")
    ok, seen = kept("return")
    t.ok("⌘Return: still keeps the peek", ok, seen)

    a_peek("shift")
    press(31, "O", "cmd", "shift")
    t.ok("⌘⇧O: the peek stays a peek", probe()["peekShown"], probe()["peekFrom"])
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
