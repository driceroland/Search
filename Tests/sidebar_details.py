#!/usr/bin/env python3
"""Integrated compact sidebar, memory and no-wake preview checks.
Build with ./build.sh debug, then python3 Tests/sidebar_details.py.
All pages and preferences live in a unique hidden test world.
"""
import subprocess
import threading
import time
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv
sv.use("sidebar-details")
t = sv.T()

def ui(**fields): return sv.cmd({"do": "ui", **fields})
def probe(): return sv.cmd({"do": "probe"})
def details(id, preview=False): return sv.cmd({"do": "tab-details", "id": id, "preview": preview})

def lights_hidden(expected):
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        if probe()["lightsHidden"] == expected:
            return True
        threading.Event().wait(0.05)
    return False


try:
    sv.setup(sidebar=True)
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", "280"], check=True)
    sv.launch()
    t.ok("details default off", not probe()["tabPreviews"] and not probe()["memoryUsage"])
    ui(previews=True, memory=True)
    t.ok("bottom-menu preferences can be changed independently of layout", probe()["tabPreviews"] and probe()["memoryUsage"])

    ui(sidebarDrag=100)
    t.ok("dragging below midpoint snaps to icons", probe()["sidebarStyle"] == "icons" and probe()["sidebarWidth"] == 42)
    t.ok("collapse preserves wide width", probe()["sideWidth"] == 280)
    t.ok("native traffic lights are hidden in compact mode", lights_hidden(True), probe())
    ui(sidebarDrag=102)
    t.ok("dragging outward above midpoint expands", probe()["sidebarStyle"] == "titles" and probe()["sidebarWidth"] == 160)
    t.ok("expanding restores native traffic lights", lights_hidden(False), probe())
    ui(side="right", sidebarDrag=250)
    t.ok("right-side expansion preserves requested width", probe()["sidebarStyle"] == "titles" and probe()["sidebarWidth"] == 250)
    ui(sidebarDrag=90)
    t.ok("right-side collapse also uses compact width", probe()["sidebarWidth"] == 42 and probe()["sideWidth"] == 250)
    ui(side="left")

    page = sv.page("memory-fixture")
    sv.cmd({"do": "wait", "id": page, "seconds": 20})
    before = details(page)
    t.ok("loaded renderer has measured RAM or an explicit shared-process label", (before["memoryBytes"] or 0) > 0 or before["sharedProcess"], before)
    t.ok("browser total is measured", (probe()["memoryBytes"] or 0) > 0, probe()["memoryBytes"])
    sv.sp("newTab")
    outcome = sv.cmd({"do": "sleep", "id": page})
    t.ok("an eligible inactive tab sleeps", outcome["asleep"], outcome)
    sleeping = details(page, preview=True)
    t.ok("sleeping preview does not recreate the web view", sleeping["asleep"] and not sleeping["built"] and not sleeping["builtAfterPreview"], sleeping)
    t.ok("sleeping tab supplies its cached thumbnail", sleeping["previewAvailable"], sleeping)
    if sleeping["sharedProcess"]:
        t.ok("shared renderer does not claim exact savings", sleeping["estimatedSavingsBytes"] is None, sleeping)
    else:
        t.ok("sleep saves the pre-sleep renderer estimate", (sleeping["estimatedSavingsBytes"] or 0) > 0, sleeping)
        again = details(page)
        t.ok("estimate survives subsequent samples", again["estimatedSavingsBytes"] == sleeping["estimatedSavingsBytes"], again)
        t.ok("known sleep estimate remains tracked", (probe()["sleepSavingsBytes"] or 0) >= sleeping["estimatedSavingsBytes"], probe())
    sv.sp("select", id=page)
    sv.cmd({"do": "wait", "id": page, "seconds": 20})
    woke = details(page)
    t.ok("wake clears sleep savings", not woke["asleep"] and woke["estimatedSavingsBytes"] is None, woke)

    artifacts = sv.ROOT / "build" / "sidebar-details"
    artifacts.mkdir(parents=True, exist_ok=True)
    ui(sidebarStyle="icons", look="light")
    sv.cmd({"do": "column", "path": str(artifacts / "compact-memory.png"), "height": 500})
    t.ok("compact rail renders with RAM enabled for hover previews", (artifacts / "compact-memory.png").stat().st_size > 500)
    sv.page("restored-active")
    sv.cmd({"do": "sleep", "id": page})
    sv.sp("save")
    sv.quit(); sv.launch()
    t.ok("detail toggles persist across restart", probe()["tabPreviews"] and probe()["memoryUsage"])
    state = sv.sp("state")
    restored = next(x for x in state["tabs"] if x["url"].endswith("/memory-fixture"))
    t.ok("inactive page is restored asleep", restored["asleep"], restored)
    if restored["asleep"]:
        unknown = details(restored["id"], preview=True)
        t.ok("restored unbuilt tab has unknown—not fabricated—savings", unknown["estimatedSavingsBytes"] is None and not unknown["builtAfterPreview"], unknown)
    ui(memory=False, previews=False)
    t.ok("details can be disabled again", not probe()["memoryUsage"] and not probe()["tabPreviews"])
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
