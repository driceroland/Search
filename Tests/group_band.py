#!/usr/bin/env python3
"""An open tab group across the top shows one band, its name to its last
tab (#921), in a hidden probe.

Build first (`./build.sh debug`), then `python3 Tests/group_band.py`.
With the tabs across the top, the row is drawn off screen (bench `strip`)
and every piece of each group's band read back: one behind the group's
name and one behind each of its tabs, in order, each running on to the
next with no gap, the first starting at the name and the last ending at
the group's last tab. A loose tab has none, and what follows an open
group, another group or a tab in none, stands 10 points after its band
rather than a tab's 2 (idea 953). Checked again after a tab is
added to the group, after one is closed, and after one is carried out of
it; a folded group has no band. Last, an open group at the end of the
row and ⌘T: the new tab is in no group, unbanded, 10 points after the
band. Pictures of the row, light and dark, with
the group coloured and not, go to GROUP_BAND_SHOTS when it is set.
"""
import os
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("group-band")
SHOTS = os.environ.get("GROUP_BAND_SHOTS") or tempfile.mkdtemp(prefix="group-band-")


def groups():
    return {g["name"]: g for g in sv.cmd({"do": "group"})["groups"]}


GAP, AIR = 2, 10


def strip(name="row.png", appearance=None):
    req = {"do": "strip", "path": os.path.join(SHOTS, name), "width": 1200}
    if appearance:
        req["appearance"] = appearance
    return sv.cmd(req)


def bands(name="row.png", appearance=None):
    return strip(name, appearance)["bands"]


def near(a, b):
    return abs(a - b) <= 0.5


def spans(drawn, group):
    """The band of GROUP (a groups() entry) is exactly its name and tabs."""
    pieces = drawn.get(group["id"], [])
    want = ["heading"] + group["tabs"]
    if [p["piece"] for p in pieces] != want:
        return False, {"pieces": [p["piece"] for p in pieces], "want": want}
    first, last = pieces[0], pieces[-1]
    if abs(first["band"][0] - first["item"][0]) > 0.5 or abs(last["band"][1] - last["item"][1]) > 0.5:
        return False, {"ends": [first, last]}
    for a, b in zip(pieces, pieces[1:]):
        # No gap and no overlap: one piece runs on exactly to the next item.
        if abs(a["band"][1] - b["item"][0]) > 0.5 or abs(a["band"][1] - b["band"][0]) > 0.5:
            return False, {"seam": [a, b]}
    if any(abs(p["height"] - 28) > 0.5 for p in pieces):
        return False, {"heights": [p["height"] for p in pieces]}
    return True, pieces


def main():
    t = sv.T()
    try:
        sv.setup(sidebar=False, **{"tabs.groups": True}); sv.launch()
        a, b, c, d, e = (sv.page(n) for n in ("a", "b", "c", "d", "e"))
        sv.cmd({"do": "group", "id": a, "new": True, "name": "Reading"})
        sv.cmd({"do": "group", "id": b, "name": "Reading"})
        sv.cmd({"do": "group", "id": c, "new": True, "name": "Plain"})
        sv.cmd({"do": "group", "name": "Reading", "colour": 3})
        sv.sp("select", id=b)

        g = groups()
        t.ok("Reading is coloured, Plain isn't", g["Reading"]["colour"] == 3 and g["Plain"]["colour"] == 0, g)
        drawn = bands("light-coloured.png", "light")
        ok, why = spans(drawn, g["Reading"])
        t.ok("Reading's band: its name and its two tabs, seamless", ok, why)
        ok, why = spans(drawn, g["Plain"])
        t.ok("Plain, uncoloured, has its band too", ok, why)
        loose = {p["piece"] for ps in drawn.values() for p in ps}
        t.ok("loose tabs have none", not ({d, e} & loose), loose)
        # The air after each band: Reading's before Plain's name, Plain's
        # before the first tab in none; between tabs in none, a tab's gap.
        drawn_all = strip()
        drawn, items = drawn_all["bands"], drawn_all["items"]
        r_end = drawn[g["Reading"]["id"]][-1]["band"][1]
        p_start = drawn[g["Plain"]["id"]][0]["item"][0]
        p_end = drawn[g["Plain"]["id"]][-1]["band"][1]
        t.ok("10 points between Reading's band and Plain's name", near(p_start - r_end, AIR), p_start - r_end)
        # The window's first, empty tab is in none too, before d.
        nxt = min(r[0] for r in items.values() if r[0] > p_end)
        t.ok("10 points between Plain's band and the tab in none after it", near(nxt - p_end, AIR), nxt - p_end)
        t.ok("a tab's gap between two tabs in none", near(items[e][0] - items[d][1], GAP), (items[d], items[e]))
        t.ok("and inside a band, a tab's gap", near(items[b][0] - items[a][1], GAP), (items[a], items[b]))
        dark = bands("dark-coloured.png", "dark")
        t.ok("drawn the same in dark", spans(dark, g["Reading"])[0] and spans(dark, g["Plain"])[0], dark)

        sv.cmd({"do": "group", "id": e, "name": "Reading"})
        g = groups()
        ok, why = spans(bands(), g["Reading"])
        t.ok("a tab added: the band reaches it", ok and e in g["Reading"]["tabs"], why)

        sv.sp("close", id=b)
        g = groups()
        ok, why = spans(bands(), g["Reading"])
        t.ok("a tab closed: the band closes up", ok and b not in g["Reading"]["tabs"], why)

        sv.cmd({"do": "group", "id": a, "out": True})
        g = groups()
        drawn = bands()
        ok, why = spans(drawn, g["Reading"])
        out = {p["piece"] for ps in drawn.values() for p in ps}
        t.ok("a tab carried out: the band ends at the group's last tab", ok and a not in g["Reading"]["tabs"], why)
        t.ok("and the tab carried out has none", a not in out, out)

        sv.cmd({"do": "group", "fold": True, "name": "Reading"})
        drawn = bands()
        t.ok("folded: no band", g["Reading"]["id"] not in drawn and spans(drawn, g["Plain"])[0], drawn)
        sv.cmd({"do": "group", "fold": True, "name": "Reading"})
        t.ok("open again: the band is back", spans(bands(), groups()["Reading"])[0])

        # Pictures, the colour off: the neutral band on both groups.
        sv.cmd({"do": "group", "id": d, "name": "Reading"})
        sv.sp("select", id=d)
        bands("light-coloured.png", "light")
        bands("dark-coloured.png", "dark")
        sv.cmd({"do": "group", "name": "Reading", "colour": 0})
        g = groups()
        drawn = bands("light-uncoloured.png", "light")
        t.ok("colour cleared: still banded, neutral", g["Reading"]["colour"] == 0 and spans(drawn, g["Reading"])[0], drawn)
        bands("dark-uncoloured.png", "dark")

        # Idea 953: an open group last in the row, then ⌘T. Plain is last.
        for x in sv.sp("state")["tabs"]:
            gs = groups()
            short = x["id"][:8].lower()
            if any(short in gg["tabs"] for gg in gs.values()):
                continue
            if x["url"]:
                sv.cmd({"do": "group", "id": short, "name": "Plain"})
            else:
                sv.sp("close", id=short)  # the window's first, empty tab
        g = groups()
        drawn_all = strip("before-cmdt.png", "dark")
        last = g["Plain"]["tabs"][-1]
        after = [i for i, r in drawn_all["items"].items() if r[0] > drawn_all["items"][last][1]]
        t.ok("the open group last in the row: nothing after it", not after, (drawn_all["items"], g))
        sv.cmd({"do": "press", "code": 17, "chars": "t", "mods": ["cmd"]})
        time.sleep(0.8)
        s = sv.sp("state")
        new = s["activeID"][:8].lower()
        g = groups()
        drawn_all = strip("after-cmdt.png", "dark")
        drawn, items = drawn_all["bands"], drawn_all["items"]
        pieces = {p["piece"] for ps in drawn.values() for p in ps}
        t.ok("⌘T's tab is in no group", not any(new in gg["tabs"] for gg in g.values()), (new, g))
        t.ok("…and isn't drawn as banded", new not in pieces, pieces)
        end = drawn[g["Plain"]["id"]][-1]["band"][1]
        t.ok("…10 points after the group's band", new in items and near(items[new][0] - end, AIR),
             (items.get(new), end))
        t.ok("the group's band still ends at its last tab", spans(drawn, g["Plain"])[0], drawn)
        print("pictures in", SHOTS)
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
