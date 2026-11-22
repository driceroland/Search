#!/usr/bin/env python3
"""An open tab group across the top shows one band, its name to its last
tab (#921), in a hidden probe.

Build first (`./build.sh debug`), then `python3 Tests/group_band.py`.
With the tabs across the top, the row is drawn off screen (bench `strip`)
and every piece of each group's band read back: one behind the group's
name and one behind each of its tabs, in order, each running on to the
next with no gap, the first starting at the name and the last ending at
the group's last tab. A loose tab has none. Checked again after a tab is
added to the group, after one is closed, and after one is carried out of
it; a folded group has no band. Pictures of the row, light and dark, with
the group coloured and not, go to GROUP_BAND_SHOTS when it is set.
"""
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("group-band")
SHOTS = os.environ.get("GROUP_BAND_SHOTS") or tempfile.mkdtemp(prefix="group-band-")


def groups():
    return {g["name"]: g for g in sv.cmd({"do": "group"})["groups"]}


def bands(name="row.png", appearance=None):
    req = {"do": "strip", "path": os.path.join(SHOTS, name), "width": 1200}
    if appearance:
        req["appearance"] = appearance
    return sv.cmd(req)["bands"]


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
        print("pictures in", SHOTS)
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
