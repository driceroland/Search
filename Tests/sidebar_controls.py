#!/usr/bin/env python3
"""Sidebar utility choices and native new-tab placement regression.
Run after ./build.sh debug. Uses a hidden, isolated profile only.
"""
import struct
import subprocess
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv
sv.use("sidebar-controls")
t = sv.T()
artifacts = sv.ROOT / "build" / "sidebar-controls"
artifacts.mkdir(parents=True, exist_ok=True)

def ui(**fields): return sv.cmd({"do": "ui", **fields})
def probe(): return sv.cmd({"do": "probe"})
def render(name, compact=True):
    path = artifacts / (name + ".png")
    result = sv.cmd({"do": "column", "path": str(path), "height": 500})
    t.ok(name + ": native sidebar rendered", path.stat().st_size > 500)
    if compact:
        t.ok(name + ": plus follows the tabs, not the window foot", result.get("newTabAfterTabs") is True, result)
        t.ok(name + ": plus has a measured position", result.get("newTabY") is not None, result)
    return result

try:
    sv.setup(sidebar=True)
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.style", "-string", "icons"], check=True)
    sv.launch()
    pages = [sv.page(x) for x in ["one", "two", "three"]]
    ui(footer="none")
    t.ok("hide everything leaves zero bottom buttons", probe()["sidebarFooterItems"] == [])
    render("compact-none")
    ui(footer="all")
    t.ok("show everything enables all ten available controls", len(probe()["sidebarFooterItems"]) == 10, probe()["sidebarFooterItems"])
    render("compact-all")
    ui(footerItems=["bookmarks", "settings"])
    t.ok("individual choices exclude unselected controls", probe()["sidebarFooterItems"] == ["bookmarks", "settings"], probe())
    render("compact-custom")
    ui(side="right", look="dark")
    render("right-dark-custom")
    ui(sidebarStyle="titles", footer="all")
    render("titles-all", compact=False)
    ui(footer="none")
    render("titles-none", compact=False)
    ui(sidebarStyle="icons", look="light", side="left")
    sv.sp("save"); sv.quit(); sv.launch()
    t.ok("an explicitly empty footer stays empty after restart", probe()["sidebarFooterItems"] == [])
    render("restarted-none")
    ui(footerItems=["tools"])
    t.ok("controls can be restored after hiding the overflow button", probe()["sidebarFooterItems"] == ["tools"])
    sv.sp("newTab")
    t.ok("new tab action still selects an empty tab", next(x for x in sv.sp("state")["tabs"] if x["id"] == sv.sp("state")["activeID"])["blank"])
    ui(footer="all")
    sv.sp("save"); sv.quit(); sv.launch()
    t.ok("show everything also persists", len(probe()["sidebarFooterItems"]) == 10)
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
