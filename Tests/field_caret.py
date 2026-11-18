#!/usr/bin/env python3
"""A long query keeps the caret and its last letter in sight (idea 736).

Build first (`./build.sh`), then `python3 Tests/field_caret.py`. It uses the
split suite's harness: started hidden in a world of its own, no window shown,
moved or resized, everything removed afterwards.

Scrolled to the end of a long query, the field editor put the caret and the
last letter a fraction of a point from the field's trailing edge (0.2 pt in
the tab's own field, 0.5 to 1 in ⌘L's and ⌘T's), and on macOS 27 the caret
and part of the letter were cut off there. The fields now keep a few points
clear past the caret (RoomyField). Read through the bench's `caret`: where
the caret and the last letter are against the field and the clip its editor
scrolls in, in window points. A hidden window draws no caret, so this checks
the geometry, not the blink.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("field-caret")
t = sv.T()
LONG = "how to keep the caret in sight at the end of a very long query in a narrow field wwwwW"
ROOM = 3  # points at least between the caret and the field's edge


def check(label):
    r = sv.cmd({"do": "caret"})
    if "error" in r:
        t.ok(f"{label}: a field is being typed in", False, r); return
    field, clip, caret, last = r["field"], r["clip"], r["caret"], r["last"]
    t.ok(f"{label}: the whole query is there, the caret at its end",
         r["text"].endswith("wwwwW") and r["selected"] == [len(r["text"]), 0], (r["text"][-10:], r["selected"]))
    t.ok(f"{label}: {ROOM} points or more between the caret and the field's edge ({field[2] - caret[2]:.1f})",
         field[2] - caret[2] >= ROOM, (field, caret))
    t.ok(f"{label}: the last letter whole, inside the field and the editor's clip",
         last[0] >= clip[0] and last[2] <= clip[2] and last[2] <= field[2] - ROOM, (last, field, clip))


try:
    sv.setup(sidebar=True); sv.launch()
    sv.page("caret"); time.sleep(1.5)
    # The page, done loading, can take the keys back from the row's field
    # just opened: then the edit is let go and begun again.
    for attempt in range(3):
        try:
            sv.cmd({"do": "tab-type", "text": LONG, "clear": True}); break
        except RuntimeError:
            sv.cmd({"do": "press", "code": 53, "chars": "\u001b"}); time.sleep(0.8)
    check("the tab's own field")
    sv.cmd({"do": "press", "code": 53, "chars": "\u001b"}); time.sleep(0.3)
    sv.cmd({"do": "field", "text": LONG, "type": True}); time.sleep(0.6)
    check("⌘L's field")
    sv.cmd({"do": "press", "code": 53, "chars": "\u001b"}); time.sleep(0.3)
    sv.cmd({"do": "press", "code": 17, "chars": "t", "mods": ["cmd"]}); time.sleep(0.5)
    sv.cmd({"do": "field", "text": LONG, "type": True}); time.sleep(0.8)
    check("⌘T's field")
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
