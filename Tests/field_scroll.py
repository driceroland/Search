#!/usr/bin/env python3
"""Two fingers over a long address being edited move along it.

Build first (`./build.sh debug`), then `python3 Tests/field_scroll.py`. It
uses the split suite's harness: started hidden in a world of its own, no
window shown, everything removed afterwards.

With the address kept in sight at the top of the column (Settings ›
Appearance › Window › Always show the address bar) and two spaces, a long
address being edited there showed only its start. A sideways stroke over it
went on to the other space, and the field didn't scroll for it either, so
the middle of the address could only be reached with ← and →. Now a stroke
that starts over the field being typed in is the field's: the space stays,
and the text moves along, sideways or up and down. Once the edit ends, the
same stroke over the column goes on to the next space as before.
"""
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("field-scroll")
t = sv.T()
IDS = [sv.FIRST_SPACE.upper(), "5E4C0000-0000-4000-8000-0000000000E1"]
LONG = "example.com/index.php/keuangan/payment/list?from=2026-01-01&to=2026-12-31&status=all&page=3&sort=date"


def world():
    os.makedirs(sv.SUPPORT, exist_ok=True)
    json.dump([{"id": x, "name": f"S{k}", "colour": 0, "sharesSignIns": True} for k, x in enumerate(IDS)],
              open(f"{sv.SUPPORT}/spaces.json", "w"))
    for k in range(len(IDS)):
        f = "session.json" if k == 0 else f"session-{IDS[k]}.json"
        json.dump({"tabs": [{"url": f"{sv.BASE}/s{k}-{i}", "title": f"s{k} {i}"} for i in range(3)], "active": 0},
                  open(f"{sv.SUPPORT}/{f}", "w"))


def along(r):
    """How far along its text the field shows, in points."""
    return r["clip"][0] - r["editor"][0]


def edit(text):
    sv.cmd({"do": "ui", "inline": True}); time.sleep(0.6)
    sv.cmd({"do": "field", "text": text}); time.sleep(0.6)
    return sv.cmd({"do": "caret"})


try:
    sv.setup(sidebar=True, spaces=True, **{"address.shown": True})
    world()
    sv.launch(); time.sleep(1.5)

    r = edit(LONG)
    t.ok("the address line's field is being typed in, the address in it",
         "error" not in r and r.get("text") == LONG, r.get("error") or r.get("text"))
    if "error" not in r:
        # The paste leaves the caret at the end: ⌘← back to the start, as
        # someone about to look along it would be.
        sv.cmd({"do": "press", "code": 123, "chars": "", "mods": ["cmd"]}); time.sleep(0.3)
        start = sv.cmd({"do": "caret"})
        first = along(start)
        t.ok("it shows the address's start, its end out of sight", start["editor"][2] > start["clip"][2] + 150,
             (start["editor"], start["clip"]))

        s = sv.cmd({"do": "spacestroke", "overField": True, "glide": 20})
        t.ok("a sideways stroke over it stays in this space", s["space"] == 0 and s["slides"] == 0,
             (s["space"], s["slides"]))
        t.ok("and the swipe lets every event of it go", all(e.endswith(":let") for e in s["events"]), s["events"][:4])

        r = sv.cmd({"do": "fieldscroll", "dx": -200})
        t.ok(f"two fingers sideways move along the text ({along(r) - first:.0f} pt)", along(r) - first > 150,
             (along(r), first, r.get("under")))
        t.ok("the caret stays where it was", r["selected"] == start["selected"], (r["selected"], start["selected"]))
        r = sv.cmd({"do": "fieldscroll", "dx": 5000})
        t.ok("and back to the start, no further", abs(along(r) - first) < 0.5, (along(r), first))
        r = sv.cmd({"do": "fieldscroll", "dy": -200})
        t.ok(f"up and down move along it too ({along(r) - first:.0f} pt)", along(r) - first > 150, (along(r), first))
        r = sv.cmd({"do": "fieldscroll", "dx": -100000})
        again = sv.cmd({"do": "fieldscroll", "dx": -500})
        t.ok("to the end, its last letter in sight, and no further",
             r["last"][2] <= r["clip"][2] and abs(along(again) - along(r)) < 0.5, (r["last"], r["clip"], along(r), along(again)))

        sv.cmd({"do": "press", "code": 53, "chars": "\u001b"}); time.sleep(0.5)
        r = edit("example.com")
        moved = sv.cmd({"do": "fieldscroll", "dx": -200}) if "error" not in r else r
        t.ok("an address that fits doesn't move", "error" not in moved and abs(along(moved) - along(r)) < 0.5,
             (r.get("error") or r.get("text"), moved.get("error") or along(moved), along(r) if "error" not in r else None))
        sv.cmd({"do": "press", "code": 53, "chars": "\u001b"}); time.sleep(0.5)

    s = sv.cmd({"do": "spacestroke"}); time.sleep(1)
    t.ok("with nothing being edited, a stroke over the column goes on one space", s["space"] == 1 and s["slides"] == 1,
         (s["space"], s["slides"]))
except Exception as error:
    t.ok("ran to the end", False, error)
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
