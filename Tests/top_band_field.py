#!/usr/bin/env python3
"""A field at the very top of a page takes its own press, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/top_band_field.py`.
With the tabs in the column, a band 12 points tall along the top of the
page moves the window (Fold.top, DragStrip). Amazon's search box lies flush
with the top of its page, and a press-drag to select its text moved the
window instead (idea 928). Here a local page has a text field flush at the
top and nothing beside it: once the pointer is over the field (bench `hit`
puts it there), a press on it is the page's and a drag in it selects text
without moving the window; on the empty band beside it, a press is still
the band's, which moves the window, and a double-click there still fills
the screen. Nothing is shown and the window never moves: the band's own
drag, the system's, is never started here.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("top-band")

PAGE = ("document.body.style.margin = '0';"
        "document.body.innerHTML = \"<input id=q value='Search Amazon for shoes and socks' "
        "style='position:fixed;top:-14px;left:0;width:360px;height:40px;margin:0;border:0;padding:0 8px;font:16px -apple-system'>\";"
        "1")


def hit(x, y, **more):
    try:
        return sv.cmd({"do": "hit", "x": x, "y": y, **more})
    except RuntimeError as e:
        return {"error": str(e)}


def run(t, cards):
    name = "as a card" if cards else "no card"
    sv.setup(sidebar=True, **{"layout.cards": cards})
    sv.launch()
    # Not filling the screen, so a double-click's zoom shows in its size.
    sv.cmd({"do": "windows", "action": "frame", "n": 1, "frame": [60, 80, 1200, 800]}); time.sleep(0.5)
    tab = sv.page("long")
    sv.cmd({"do": "select", "id": tab}); sv.cmd({"do": "wait", "id": tab, "seconds": 5})
    sv.cmd({"do": "eval", "id": tab, "js": PAGE}); time.sleep(0.6)
    # Where the page starts, beside the column.
    left = next((x for x in range(0, 900, 4) if hit(x, 300)["view"].startswith("PageView")), None)
    t.ok(f"{name}: the page is beside the column", left is not None and left > 40, left)
    if left is None:
        sv.quit(); return
    # The band is the top 12 points of the window. As a card, the page
    # starts 8 points down, so the band's last 4 lie over its top; without
    # the card, all 12 do. Asked 10 down, where the field's text is.
    field, empty = (left + 120, 10), (left + 600, 10)
    sel = "var q = document.getElementById('q'); [document.activeElement === q, q.selectionEnd - q.selectionStart]"

    # The pointer comes over the field: the page is asked what is there.
    hit(*field); time.sleep(0.5)
    over = hit(*field)
    t.ok(f"{name}: over the field at the top, a press is the page's", over["view"].startswith("PageView"), over)
    # A press handed to the page from here doesn't make it the window's
    # first responder as a real one would, and its first drag only focuses
    # the field: one drag below the band first, its selection put back to
    # nothing, so the one in the band is what selects.
    hit(field[0], 40, drag=60.0)
    sv.cmd({"do": "eval", "id": tab, "js": "document.getElementById('q').setSelectionRange(0, 0); 1"})
    hit(*field); time.sleep(0.5)
    drag = hit(*field, drag=120.0)
    t.ok(f"{name}: a drag in the field doesn't move the window", drag.get("moved") is False and drag.get("view", "").startswith("PageView"), drag)
    picked = sv.cmd({"do": "eval", "id": tab, "js": sel}).get("value")
    t.ok(f"{name}: a drag in the field at the top selects its text", picked and picked[0] is True and picked[1] > 0, picked)

    # The empty band beside it is still the window's.
    hit(*empty); time.sleep(0.5)
    bare = hit(*empty)
    t.ok(f"{name}: over empty page at the top, a press is the band's (it moves the window)", bare["view"].startswith("Strip"), bare)
    t.ok(f"{name}: the band's drag is never sent from here", "error" in hit(*empty, drag=40.0))
    if cards:
        t.ok(f"{name}: above the page, in the card's gap, the band's", hit(left + 120, 3)["view"].startswith("Strip"))
    zoom = hit(*empty, double=True)
    t.ok(f"{name}: a double-click on the empty band still fills the screen", zoom.get("before") != zoom.get("after"), zoom)

    # Below the band, the page as ever; the column's top still the window's.
    t.ok(f"{name}: below the band, the page", hit(left + 600, 40)["view"].startswith("PageView"))
    col = hit(20, 5)
    t.ok(f"{name}: the column's top is still the window's to drag", col["view"].startswith("Strip"), col)
    sv.quit()



def main():
    t = sv.T()
    try:
        for cards in (True, False):
            run(t, cards)
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
