#!/usr/bin/env python3
"""A tab across the top never shows its mark and a lone "…", in a hidden
probe.

Build first (`./build.sh debug`), then `python3 Tests/tab_titles.py`.
With the tabs across the top, the row is drawn off screen (bench `strip`)
from narrow to wide with 4 to 12 tabs, and every title read back: what it
says, how wide it was laid out, and what of it is left once cut. A tab too
narrow for three letters or so of its title shows its mark alone; one with
a title shows at least that much of it, or all of it. The tab you're on
says where its page is (Settings › Tabs › Show the address), cut in the
middle: never down to "…" either. Checked with loose tabs, then with a
pinned tab, a group and a pair in Split View in the row. Pictures of the
row go to TAB_TITLES_SHOTS when it is set.
"""
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("tab-titles")
SHOTS = os.environ.get("TAB_TITLES_SHOTS") or tempfile.mkdtemp(prefix="tab-titles-")
NAMES = ["Quarterly-planning-notes", "Inbox", "Design-review-feedback", "Weather",
         "The-long-read-on-typography", "Maps", "Release-checklist", "Recipes-for-the-week",
         "Docs", "Train-times-to-the-coast", "Calendar", "Photographs-from-the-trip"]
WIDTHS = range(480, 1841, 40)


def strip(width, tag):
    return sv.cmd({"do": "strip", "path": os.path.join(SHOTS, f"{tag}-{width}.png"), "width": width})["titles"]


def letters(visible):
    return len(visible.replace("…", "").strip())


def stubs(titles):
    """Every shown line cut down to "…", or to fewer than three letters of
    a title (two of an address, one either side of the "…")."""
    bad = []
    for t in titles:
        if not t["shown"] or t["visible"] == t["text"]:
            continue
        least = 2 if t["line"] == "rest" else 3
        if t["visible"] in ("", "…") or letters(t["visible"]) < least:
            bad.append({k: t[k] for k in ("tab", "line", "text", "visible", "width")})
    return bad


def sweep(t, tag, counts, opened):
    """Opens up to each count of tabs, drawing the row at every width; the
    titles must never be stubs, and the row must title some and not others,
    or the sweep proved nothing."""
    cut = titled = said = 0
    for count in counts:
        while len(opened) < count:
            opened.append(sv.page(NAMES[len(opened) % len(NAMES)]))
        bad = []
        for width in WIDTHS:
            titles = strip(width, f"{tag}-{count}")
            bad += [dict(b, row=width) for b in stubs(titles)]
            shown = [x for x in titles if x["shown"] and x["line"] == "title"]
            titled += len(shown)
            cut += sum(1 for x in shown if x["visible"] != x["text"])
            said += sum(1 for x in titles if x["shown"] and x["line"] == "rest")
        t.ok(f"{tag}, {count} tabs: no title cut to a lone '…' or a stub, {WIDTHS.start}–{WIDTHS.stop - 1} wide",
             not bad, bad[:6])
    t.ok(f"{tag}: titles were drawn, some of them cut", titled > 0 and cut > 0, {"titled": titled, "cut": cut})
    return said


def main():
    t = sv.T()
    try:
        sv.setup(sidebar=False, **{"tabs.groups": True, "tabs.address": True}); sv.launch()
        opened = []
        sweep(t, "loose", [4], opened)

        # The tab you're on is one in the middle of the row, saying its
        # address while there is room for it beside its port, its title after.
        sv.sp("select", id=opened[2])
        said = sweep(t, "picked", [4, 6, 8, 10, 12], opened)
        t.ok("the tab you're on said its address where there was room", said > 0, said)

        # A pinned square and a group take their room off the top.
        sv.cmd({"do": "pin", "id": opened[0]})
        sv.cmd({"do": "group", "id": opened[1], "new": True, "name": "Reading list"})
        sv.cmd({"do": "group", "id": opened[2], "name": "Reading list"})
        sweep(t, "pinned-grouped", [12], opened)

        # A pair in Split View: half again as wide as a tab, each half its own title.
        sv.sp("pair", id=opened[4], **{"with": opened[3]}, side="right")
        sweep(t, "split", [12], opened)
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
