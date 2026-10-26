#!/usr/bin/env python3
"""The column as icons only (idea 413), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/icon_column.py`. It uses the
split suite's harness: started hidden in a world of its own, no window made,
shown or brought forward, everything removed afterwards. Checked through
the bench (`icons`, `split`): the setting turns the rows into tiles of a
fixed narrow width, the lights stack in the column, a tile's tooltip is its
title (and what the row would have said beside it), a drag still moves a
tab, a pair is one tile of two marks, a group's tiles fold with it, and
turning it off gives the column its pulled width back. What can only be
seen — the tooltip's delay, the look — is on the RC list.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bld-ai-icons")

t = sv.T()
def icons(**f): return sv.cmd({"do": "icons", **f})
def state(): return sv.sp("state")
def name_of(st): return {x["id"]: x["url"].rsplit("/", 1)[-1] for x in st["tabs"]}
def order(st): m = name_of(st); return [m[x["id"]] for x in st["tabs"] if not x.get("blank")]
def tiles(r): return {x["id"]: x for x in r["tiles"]}
def settle(want, within=4):
    """The column again until `want` holds of it: tiles are measured a frame
    or two after a change."""
    until = time.time() + within
    r = icons()
    while not want(r) and time.time() < until:
        time.sleep(0.15); r = icons()
    return r

try:
    sv.setup(sidebar=True, splitView=True, **{"tabs.groups": True}); sv.launch()
    a = sv.page("a"); b = sv.page("b"); c = sv.page("c"); d = sv.page("d"); e = sv.page("e")
    st = state()
    t.ok("start: five tabs down the side", order(st) == ["a", "b", "c", "d", "e"], order(st))
    r = icons()
    t.ok("off by default", r["on"] is False and r["layout"] == "left" and r["columnWidth"] == r["sideWidth"], r)
    before_lights = r["lights"]
    t.ok("off: the lights side by side", len({y for _, y in before_lights}) == 1, before_lights)

    # On, as Settings' Icons only.
    r = icons(on=True)
    r = settle(lambda r: all(i in tiles(r) for i in [a, b, c, d, e]))
    ts = tiles(r)
    t.ok("on: Icons only", r["on"] is True and r["layout"] == "icons", r)
    t.ok("on: a fixed narrow column, 52 pt", r["columnWidth"] == 52, r["columnWidth"])
    t.ok("on: the width pulled is kept for later", r["sideWidth"] >= 176, r["sideWidth"])
    t.ok("on: every tab a tile", all(i in ts for i in [a, b, c, d, e]), list(ts))
    sizes = {(round(x["frame"][2]), round(x["frame"][3])) for x in ts.values()}
    t.ok("on: tiles 32 by 32", sizes == {(32, 32)}, sizes)
    xs = {round(x["frame"][0]) for x in ts.values()}
    t.ok("on: tiles inside the column, 10 from its edge", xs == {10}, xs)
    ys = [ts[i]["frame"][1] for i in [a, b, c, d, e]]
    t.ok("on: one under the other, in the tabs' order", ys == sorted(ys) and len(set(ys)) == 5, ys)
    steps = {round(ys[i + 1] - ys[i]) for i in range(4)}
    t.ok("on: a tile and a 2 pt gap apart", steps == {34}, steps)
    lights = r["lights"]
    t.ok("on: the lights stacked, one above the other",
         len({x for x, _ in lights}) == 1 and [y for _, y in lights] == sorted(y for _, y in lights) and len({y for _, y in lights}) == 3, lights)
    t.ok("on: the lights over the column, clear of the first tile",
         all(x + 14 <= 52 for x, _ in lights) and max(y for _, y in lights) + 7 < ys[0], (lights, ys[0]))

    # The tooltip: the title, nothing sliding out.
    t.ok("tooltip: a tab's title", ts[b]["tip"].split("\n")[0] == "b", ts[b]["tip"])
    t.ok("tooltip: no address on a tab you're not on", "\n" not in ts[b]["tip"], ts[b]["tip"])
    sv.sp("select", id=a); time.sleep(0.4)
    tip = settle(lambda r: "\n" in tiles(r)[a]["tip"])
    lines = tiles(tip)[a]["tip"].split("\n")
    t.ok("tooltip: the tab you're on says where it is (plain http warns, as at rest)",
         lines[0] == "a" and len(lines) >= 2 and "127.0.0.1" in lines[1], lines)

    # A drag still moves a tab: what the tile's drag calls when it passes
    # another (Carried.move → Browser.moveDisplayedTab), through the bench.
    # The hand itself — a tile picked up and carried along the column — is
    # driven in IconColumnTests (`swift test --filter IconColumnTests`), in
    # a window off every screen: a hidden probe's window gets no gestures.
    sv.sp("move", id=c, to=0); time.sleep(0.6)
    st = state()
    t.ok("move: the tile carried to the top is first", order(st)[0] == "c", order(st))
    r = settle(lambda r: tiles(r)[c]["frame"][1] < tiles(r)[a]["frame"][1])
    t.ok("move: and drawn there", tiles(r)[c]["frame"][1] < tiles(r)[a]["frame"][1], (tiles(r)[c]["frame"], tiles(r)[a]["frame"]))

    # A pair is one tile with both marks.
    sv.sp("pair", id=e, **{"with": d}, side="right"); time.sleep(0.8)
    r = settle(lambda r: tiles(r).get(d, {}).get("pair") == e)
    ts = tiles(r)
    t.ok("pair: one tile of two", ts.get(d, {}).get("pair") == e, ts.get(d))
    r = settle(lambda r: round(tiles(r)[e]["frame"][1] - tiles(r)[d]["frame"][1]) == 32 and round(tiles(r)[d]["frame"][2]) == 32); ts = tiles(r)
    t.ok("pair: its marks one above the other",
         d in ts and e in ts and round(ts[d]["frame"][0]) == round(ts[e]["frame"][0])
         and round(ts[e]["frame"][1] - ts[d]["frame"][1]) == 32, (ts.get(d), ts.get(e)))
    t.ok("pair: each half its own tooltip", ts[d]["tip"].startswith("d") and ts[e]["tip"].startswith("e"), (ts[d]["tip"], ts[e]["tip"]))

    # A group: a short heading, its tiles under it, folded with it.
    sv.sp("group", id=b); time.sleep(0.6)
    st = state()
    group = next((g["id"] for g in st.get("groups", []) if b in g.get("tabs", [])), None) or (st.get("groups") or [{}])[0].get("id")
    r = settle(lambda r: b in tiles(r))
    t.ok("group: its tile is drawn", b in tiles(r), list(tiles(r)))
    if group:
        sv.sp("collapse", group=group); time.sleep(0.6)
        r = settle(lambda r: b not in tiles(r))
        t.ok("group: folded, its tiles go", b not in tiles(r), list(tiles(r)))
        sv.sp("collapse", group=group); time.sleep(0.6)
        r = settle(lambda r: b in tiles(r))
        t.ok("group: unfolded, back", b in tiles(r), list(tiles(r)))
    else:
        t.ok("group: made", False, st.get("groups"))

    # Closing goes through the tab's own close, as the menu and the middle
    # button do: its tile goes.
    sv.sp("close", id=c); time.sleep(0.6)
    r = settle(lambda r: c not in tiles(r))
    t.ok("close: its tile goes", c not in tiles(r), list(tiles(r)))

    # Off: the titles and the width pulled come back, the lights a row again.
    r = icons(on=False); time.sleep(0.6); r = icons()
    t.ok("off: the column's own width again", r["on"] is False and r["columnWidth"] == r["sideWidth"] and r["columnWidth"] >= 176, r)
    t.ok("off: the lights a row again", len({y for _, y in r["lights"]}) == 1, r["lights"])
    t.ok("off: no tiles left", tiles(r) == {}, list(tiles(r)))
finally:
    sv.finish()
t.done()
sys.exit(1 if t.failed else 0)
