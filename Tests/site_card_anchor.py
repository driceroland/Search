#!/usr/bin/env python3
"""The site card hangs from the tab it is about after a double-click on a
tab (#1310), in a hidden probe.

Build first (`./build.sh debug`), then `python3 Tests/site_card_anchor.py`.
A double-click on a tab you aren't on is two clicks: the first picks the
tab, the second, on the tab now in front, opens its address with the card
under it, while the row is still settling. The card came up near the
middle of the screen. Checked here, in the column and in the row across
the top: picked and opened at once, and once the row has settled, the card
stands under the field with the caret, its left edge 12 points before the
field's and its top 12 points below it; and with the card up, a tab
before it closing moves the field, and the card goes with it. The card is a child window of the
hidden probe's window, never on a screen.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("site-card-anchor")


def frames():
    p = sv.cmd({"do": "probe"})
    return {**p["siteCardFrames"], "editing": p["tabEditing"]}


def hangs(f):
    if "card" not in f or "field" not in f: return False
    cx, cy, cw, ch = f["card"]; fx, fy, fw, fh = f["field"]
    return abs(cx - (fx - 12)) <= 1 and abs((cy + ch) - (fy - 12)) <= 1


def run(t, name, sidebar):
    sv.setup(sidebar=sidebar); sv.launch()
    a = sv.page("first")
    b = sv.page("second")
    for at, (pick, then) in enumerate([(a, 0), (b, 0), (a, 0.05), (b, 0.15)]):
        # The first click picks the tab, the second opens its address.
        sv.sp("select", id=pick)
        if then: time.sleep(then)
        sv.cmd({"do": "ui", "opentab": True})
        time.sleep(0.15)
        early = frames()
        time.sleep(0.8)
        late = frames()
        t.ok(f"{name}, double-click {at + 1}: the card is up", "card" in late, late)
        t.ok(f"{name}, double-click {at + 1}: the card hangs from the tab's field once settled", hangs(late), late)
        t.ok(f"{name}, double-click {at + 1}: it hangs there from the start", "card" not in early or hangs(early) or early.get("card") == late.get("card"), (early, late))
        sv.cmd({"do": "ui", "finishedit": True}); time.sleep(0.4)

    # Up, and the tab moves: a tab before it closes, and the card goes
    # with the field.
    c = sv.page("third")
    sv.cmd({"do": "ui", "opentab": True}); time.sleep(0.8)
    before = frames()
    sv.sp("close", id=a); time.sleep(0.8)
    after = frames()
    t.ok(f"{name}: the card is up before the tab moves", hangs(before), before)
    t.ok(f"{name}: the tab moved", before.get("field") != after.get("field"), (before, after))
    t.ok(f"{name}: the card went with it", hangs(after), after)
    sv.quit()


def main():
    t = sv.T()
    try:
        run(t, "column", True)
        run(t, "top row", False)
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
