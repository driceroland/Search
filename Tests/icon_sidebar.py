#!/usr/bin/env python3
"""Favicon-only sidebar: persistence, geometry, tab behavior and render smoke tests.

Build first (./build.sh debug), then python3 Tests/icon_sidebar.py.
Uses the existing hidden, isolated probe harness; never controls a personal session.
Snapshots stay in build/icon-sidebar/ for manual visual inspection.
"""
import struct
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv

sv.use("icon-sidebar")
t = sv.T()
artifacts = sv.ROOT / "build" / "icon-sidebar"
artifacts.mkdir(parents=True, exist_ok=True)

def ui(**fields):
    return sv.cmd({"do": "ui", **fields})

def probe():
    return sv.cmd({"do": "probe"})

def image(name, height=680):
    path = artifacts / f"{name}.png"
    sv.cmd({"do": "column", "path": str(path), "height": height})
    data = path.read_bytes()
    t.ok(f"{name}: a rendered PNG", data[:8] == b"\x89PNG\r\n\x1a\n" and len(data) > 500, len(data))
    width_px, height_px = struct.unpack(">II", data[16:24])
    t.ok(f"{name}: narrow column geometry", abs(width_px / height_px - 42 / height) < 0.001, (width_px, height_px))

try:
    sv.setup(sidebar=True, **{"tabs.groups": True, "pins.list": True, "splitView": True})
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", "300"], check=True)
    sv.launch()
    state = probe()
    t.ok("existing users keep the titled sidebar by default", state["iconsStyle"] == "column", state)
    t.ok("the saved normal width is used", state["columnWidth"] == 300, state)

    # One entry point: Tabs › Icons only. Its look is a separate setting.
    ui(layout="icons")
    state = probe()
    t.ok("icons only starts as the standard 52-point column",
         state["iconsStyle"] == "column" and state["columnWidth"] == 52 and not state["iconDynamic"], state)
    ui(iconsStyle="dynamic")
    state = probe()
    t.ok("the dynamic rail uses the fixed 42-point width",
         state["iconsStyle"] == "dynamic" and state["iconDynamic"] and state["columnWidth"] == 42, state)
    t.ok("the rail does not overwrite the normal width", state["sideWidth"] == 300, state)
    ui(sidebar=False)
    t.ok("top tabs ignore the compact width", probe()["columnWidth"] == 300, probe())
    ui(sidebar=True)
    t.ok("returning to the sidebar restores the rail", probe()["columnWidth"] == 42)
    try:
        ui(iconsStyle="invalid")
        t.ok("invalid style is rejected", False)
    except RuntimeError:
        t.ok("invalid style is rejected without changing mode", probe()["iconsStyle"] == "dynamic")

    # The opt-in details are the same in both looks: hover previews, RAM in
    # them, and the configurable footer. Only the rail's own chrome differs.
    ui(iconsStyle="column", footer="all", previews=True, memory=True)
    state = probe()
    t.ok("the standard column keeps its 52-point width",
         state["columnWidth"] == 52 and not state["iconDynamic"], state)
    t.ok("previews and RAM are offered in both looks", state["tabPreviews"] and state["memoryUsage"], state)
    t.ok("the footer is the configurable one in both looks",
         len(state["sidebarFooterItems"]) == 10, state["sidebarFooterItems"])
    standard = artifacts / "standard-column.png"
    sv.cmd({"do": "column", "path": str(standard), "height": 680})
    width_px, height_px = struct.unpack(">II", standard.read_bytes()[16:24])
    t.ok("standard column: rendered at 52 points", abs(width_px / height_px - 52 / 680) < 0.001, (width_px, height_px))
    ui(iconsStyle="dynamic", footer="none")

    a, b, c, d, e = [sv.page(name) for name in ["alpha", "bravo", "charlie", "delta", "echo"]]
    sv.cmd({"do": "pin", "id": a})
    sv.cmd({"do": "pin", "id": b, "listed": True})
    sv.sp("group", id=c)
    st = sv.sp("state")
    t.ok("both kinds of pin are kept", a in st["pins"] and b in st["listed"], st)
    t.ok("groups remain available", any(st["groupIDs"]), st["groupIDs"])
    sv.sp("pair", id=e, **{"with": d}, side="right")
    sv.sp("select", id=d)
    st = sv.sp("state")
    t.ok("split tabs remain paired", len(st["splits"]) == 1 and set(st["visibleIDs"]) == {d, e}, st["splits"])
    sv.sp("focus", id=e)
    t.ok("both halves can be focused", sv.sp("state")["activeID"] == e)

    ui(look="light", side="left")
    image("light-left")
    ui(side="right")
    t.ok("right-side rail uses the same compact width", probe()["sidePosition"] == "right" and probe()["columnWidth"] == 42)
    image("light-right")
    ui(look="dark")
    image("dark-right")
    ui(fullscreen=True)
    image("dark-fullscreen")
    ui(fullscreen=False, folded=True, peek=True)
    path = artifacts / "folded-right.png"
    sv.cmd({"do": "fold", "path": str(path)})
    t.ok("folded rail renders without errors", path.exists() and path.stat().st_size > 500)
    ui(folded=False, peek=False, side="left", look="light")

    # Enough tabs to require scrolling; choosing the last must still be valid.
    extra = [sv.page(f"overflow-{i}") for i in range(14)]
    sv.sp("select", id=extra[-1])
    t.ok("overflow selection remains reachable", sv.sp("state")["activeID"] == extra[-1])
    image("overflow", height=460)
    before = [x["id"] for x in sv.sp("state")["tabs"]]
    sv.sp("move", id=extra[-1], to=before.index(extra[1]))
    after = [x["id"] for x in sv.sp("state")["tabs"]]
    t.ok("tab ordering still changes in icon mode", after.index(extra[-1]) < after.index(extra[1]), after)
    sv.sp("close", id=extra[0])
    t.ok("tabs can still be closed", extra[0] not in [x["id"] for x in sv.sp("state")["tabs"]])

    sv.sp("save")
    sv.quit()
    sv.launch()
    state = probe()
    t.ok("the icons-only choice and its look survive restart",
         state["iconsStyle"] == "dynamic" and state["columnWidth"] == 42, state)
    t.ok("the normal width survives restart too", state["sideWidth"] == 300, state)
    ui(layout="left")
    t.ok("switching back restores the saved normal width", probe()["columnWidth"] == 300)
    title_path = artifacts / "titled-left.png"
    sv.cmd({"do": "column", "path": str(title_path), "height": 680})
    t.ok("titled sidebar separator render remains available", title_path.stat().st_size > 500)
    ui(layout="icons", iconsStyle="dynamic")
    sv.quit()
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.icons.style", "-string", "future-style"], check=True)
    sv.launch()
    t.ok("unknown stored style falls back to the standard column", probe()["iconsStyle"] == "column")
finally:
    t.done()
    sv.finish()

sys.exit(1 if t.failed else 0)
