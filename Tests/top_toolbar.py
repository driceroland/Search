#!/usr/bin/env python3
"""Top hover toolbar: reveal lifecycle, native lights and custom controls.
Build first; uses the same hidden isolated probe as other sidebar suites.
"""
import json
import struct
import subprocess
import sys
import threading
import time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv
sv.use("top-toolbar")
t = sv.T()
artifacts = sv.ROOT / "build" / "top-toolbar"
artifacts.mkdir(parents=True, exist_ok=True)

def ui(**fields): return sv.cmd({"do": "ui", **fields})
def probe(): return sv.cmd({"do": "probe"})
def wait_for(key, expected, timeout=3):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if probe()[key] == expected: return True
        threading.Event().wait(.05)
    return False

def render(name, width=1100):
    path = artifacts / (name + ".png")
    result = sv.cmd({"do": "top-toolbar-shot", "path": str(path), "width": width})
    data = path.read_bytes()
    w, h = struct.unpack(">II", data[16:24])
    t.ok(name + ": strip rendered at 44 points high", abs(w/h-width/44) < .001 and len(data) > 500, (w,h,len(data)))
    return result

try:
    sv.setup(sidebar=True)
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.style", "-string", "icons"], check=True)
    sv.launch()
    page = sv.page("toolbar-page")
    sv.cmd({"do": "wait", "id": page, "seconds": 20})
    initial = probe()
    t.ok("top edge reveal enabled by default", initial["topToolbarEnabled"])
    t.ok("strip initially hidden", not initial["topToolbarRevealed"])
    t.ok("native controls initially hidden", initial["lightsHidden"])
    old_width = sv.ev(page, "innerWidth")
    old_height = sv.ev(page, "innerHeight")
    ui(topEdge=True)
    t.ok("edge dwell reveals the strip", wait_for("topToolbarRevealed", True), probe())
    t.ok("native window controls reveal with strip", wait_for("lightsHidden", False), probe())
    end = time.monotonic() + 3
    while time.monotonic() < end and sv.ev(page,"innerHeight") != old_height - 44:
        threading.Event().wait(.05)
    t.ok("revealing pushes page down and reserves exactly the strip height", sv.ev(page,"innerWidth")==old_width and sv.ev(page,"innerHeight")==old_height-44, probe().get("activePageFrame"))
    baseline = render("default-light")
    fixture = artifacts / "extension-fixture"
    fixture.mkdir(exist_ok=True)
    (fixture / "manifest.json").write_text(json.dumps({"manifest_version":3,"name":"Toolbar width fixture","version":"1.0","action":{"default_title":"Fixture action"}}))
    sv.cmd({"do":"ext-folder","path":str(fixture),"yes":True})
    end = time.monotonic() + 12
    extension = None
    while time.monotonic() < end:
        extension = next((x for x in sv.cmd({"do":"extensions"})["extensions"] if x["name"]=="Toolbar width fixture" and x["loaded"]),None)
        if extension:break
        threading.Event().wait(.1)
    t.ok("isolated extension fixture loaded", extension is not None)
    if extension:
        sv.cmd({"do":"ext-pin","id":extension["id"],"on":False})
        unpinned = render("extension-unpinned")
        sv.cmd({"do":"ext-pin","id":extension["id"],"on":True})
        pinned = render("extension-pinned")
        t.ok("pinned extension widens the right tools group", pinned["toolsWidth"] > unpinned["toolsWidth"] + 20, (unpinned,pinned))
        t.ok("URL field shrinks to accommodate pinned extension", pinned["addressWidth"] < unpinned["addressWidth"] - 20, (unpinned,pinned))
        t.ok("extension width is taken from URL field, not clipped", abs((unpinned["addressWidth"]-pinned["addressWidth"])-(pinned["toolsWidth"]-unpinned["toolsWidth"])) < 1, (unpinned,pinned))
        sv.cmd({"do":"ext-pin","id":extension["id"],"on":False})
        restored = render("extension-unpinned-again")
        t.ok("unpinning returns space to URL bar", abs(restored["addressWidth"]-unpinned["addressWidth"])<1, (unpinned,restored))
        sv.cmd({"do":"ext-remove","id":extension["id"]})
    navigated = sv.cmd({"do": "top-address-submit", "text": sv.BASE + "/toolbar-address-navigation"})
    t.ok("real compact address field handles submit", navigated["handled"], navigated)
    sv.cmd({"do": "wait", "id": page, "seconds": 20})
    t.ok("compact address field navigates active tab", sv.ev(page, "location.href").endswith("/toolbar-address-navigation"))
    ui(topEdge=True)
    wait_for("topToolbarRevealed", True)
    searched = sv.cmd({"do": "top-address-submit", "text": "hover toolbar test query"})
    t.ok("compact address field accepts search terms", searched["handled"])
    target = next(x["url"] for x in sv.sp("state")["tabs"] if x["id"] == page)
    t.ok("search uses configured browser destination policy", "/search?" in target and "hover" in target, target)
    sv.cmd({"do": "go", "id": page, "url": sv.BASE + "/toolbar-page"})
    sv.cmd({"do": "wait", "id": page, "seconds": 20})

    outside_start = time.monotonic()
    ui(topEdge=False, topOutsideWindow=True)
    threading.Event().wait(.4)
    t.ok("leaving the window retains Helium's longer grace", probe()["topToolbarRevealed"])
    did_hide = wait_for("topToolbarRevealed", False, timeout=4)
    outside_elapsed = time.monotonic() - outside_start
    t.ok("outside-window grace matches the three-second source value", did_hide and 2.9 <= outside_elapsed <= 4.2, outside_elapsed)
    ui(topEdge=True)
    wait_for("topToolbarRevealed", True)
    ui(topEdge=False)
    t.ok("leaving top hides after grace", wait_for("topToolbarRevealed", False), probe())
    t.ok("native controls hide again", wait_for("lightsHidden", True), probe())
    end = time.monotonic() + 3
    while time.monotonic() < end and sv.ev(page,"innerHeight") != old_height:
        threading.Event().wait(.05)
    t.ok("hiding restores full page height", sv.ev(page,"innerHeight")==old_height)

    ui(topEdge=True)
    wait_for("topToolbarRevealed", True)
    ui(topEditing=True, topEdge=False)
    threading.Event().wait(.55)
    t.ok("address editing holds strip open", probe()["topToolbarRevealed"])
    ui(topEditing=False)
    t.ok("finishing edit permits hide", wait_for("topToolbarRevealed", False))
    ui(topEdge=True)
    wait_for("topToolbarRevealed", True)
    ui(topMenu=True, topEdge=False)
    threading.Event().wait(.55)
    t.ok("menu tracking holds strip open", probe()["topToolbarRevealed"])
    ui(topMenu=False)
    t.ok("closing menu permits hide", wait_for("topToolbarRevealed", False))

    ui(footer="none", topItems="all", topEdge=True)
    wait_for("topToolbarRevealed", True)
    t.ok("all thirteen top controls available", len(probe()["topToolbarItems"])==13)
    t.ok("top choices independent of bottom buttons", probe()["sidebarFooterItems"]==[])
    render("all-wide")
    ui(look="dark")
    render("all-dark-narrow", width=640)
    ui(topControls=["address","extensions","settings"], topEdge=True)
    t.ok("custom top controls kept exactly", set(probe()["topToolbarItems"])=={"address","extensions","settings"})
    t.ok("deselecting window controls hides native buttons", wait_for("lightsHidden", True))
    render("custom-dark")
    ui(topItems="none")
    t.ok("hide everything removes strip eligibility", wait_for("topToolbarRevealed", False) and probe()["topToolbarItems"]==[])
    ui(topEdge=True)
    threading.Event().wait(.25)
    t.ok("empty top strip cannot reveal", not probe()["topToolbarRevealed"])
    sv.sp("save");sv.quit();sv.launch()
    t.ok("explicit empty selection survives restart", probe()["topToolbarItems"]==[])
    ui(topItems="all", topEnabled=False, topEdge=True)
    threading.Event().wait(.25)
    t.ok("disabled reveal stays hidden", not probe()["topToolbarRevealed"])
    ui(topEnabled=True, topEdge=True)
    t.ok("re-enabling restores reveal", wait_for("topToolbarRevealed", True))
    ui(fullscreen=True)
    t.ok("native fullscreen suppresses the custom strip", wait_for("topToolbarRevealed", False))
    ui(fullscreen=False, sidebarStyle="titles")
    t.ok("titled layout suppresses the strip", not probe()["topToolbarRevealed"])
    ui(sidebarStyle="icons", topControls=["windowControls","address","tools"], topEdge=True)
    t.ok("returning to compact mode restores reveal", wait_for("topToolbarRevealed", True))
    sv.sp("save");sv.quit();sv.launch()
    t.ok("custom selection and enabled state survive restart", set(probe()["topToolbarItems"])=={"windowControls","address","tools"} and probe()["topToolbarEnabled"])
finally:
    t.done();sv.finish()
sys.exit(1 if t.failed else 0)
