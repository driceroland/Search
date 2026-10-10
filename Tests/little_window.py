#!/usr/bin/env python3
"""A link's small window (Little.swift), in a hidden probe: its keys, and a
launch made by its link with several windows saved.

Build first (`./build.sh`), then `python3 Tests/little_window.py`. It uses the
split suite's harness in a world of its own (little-tests): started hidden,
no window shown, everything removed afterwards. Small windows are made unseen
by the bench, and keys are pressed on them through the app's own event queue
(`press` with "little"), so they meet the same monitors a real press does.

A test run takes no links from outside, so a launch made by a link is a
launch handed SEARCH_LINK, taken where the Apple Event would be.

Copying writes the Mac's pasteboard; the text on it before is put back.
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("little-tests")
t = sv.T()


def little(what): return sv.cmd({"do": "little", "what": what})
def press(code, chars, *mods): sv.cmd({"do": "press", "code": code, "chars": chars, "mods": list(mods), "little": True}); time.sleep(0.3)
def paste(): return subprocess.run(["pbpaste"], capture_output=True, text=True).stdout
def windows(**f): return sv.cmd({"do": "windows", **f})
def records(): return json.load(open(f"{sv.SUPPORT}/windows.json"))
def kept_rows(): return [u for r in records()[1:] for shape in r.get("rows", {}).values() for u in json.dumps(shape).split('"') if u.startswith(sv.BASE)]


def launch_with(link):
    """sv.launch, handed a link to launch with."""
    if os.path.exists(sv.SOCK): os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={sv.W}", "--env", f"SEARCH_LINK={link}", sv.APP])
    for _ in range(150):
        if os.path.exists(sv.SOCK): break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update((sv.running() - before) & sv.holding())


saved = subprocess.run(["pbpaste"], capture_output=True).stdout
try:
    sv.setup(); sv.launch()

    # ⌘⇧C: this page's address, said at the window's foot — not the tab
    # behind it in the browser's window, which the menu would copy.
    little(f"{sv.BASE}/copied"); time.sleep(2)
    subprocess.run(["pbcopy"], input=b"before")
    press(8, "c", "cmd", "shift")
    t.ok("⌘⇧C copies the small window's address", paste() == f"{sv.BASE}/copied", paste())
    t.ok("⌘⇧C says so in the small window", little("look")["said"] == "Address copied", little("look"))
    time.sleep(2)
    t.ok("and then stops saying it", little("look")["said"] == "")

    # Zoom: its page, by the browser's steps, said at its own foot.
    press(24, "=", "cmd")
    st = little("look")
    t.ok("⌘+ zooms the small window's page", abs(st["zoom"] - 1.1) < 0.01, st["zoom"])
    t.ok("and says so there", st["said"] == "110%", st["said"])
    press(27, "-", "cmd"); press(27, "-", "cmd")
    t.ok("⌘- zooms it out", little("look")["zoom"] < 1, little("look")["zoom"])
    press(29, "0", "cmd")
    t.ok("⌘0 puts it back", abs(little("look")["zoom"] - 1) < 0.01, little("look")["zoom"])

    # ⌘W and Escape close it; the browser's row is as it was.
    tabs = little("look")["tabs"]
    press(13, "w", "cmd")
    st = little("look")
    t.ok("⌘W closes the small window", st["littles"] == [], st["littles"])
    t.ok("⌘W leaves the browser's tabs alone", st["tabs"] == tabs, (tabs, st["tabs"]))
    little(f"{sv.BASE}/escaped"); time.sleep(1.5)
    press(53, "\u001b")
    t.ok("Escape closes it", little("look")["littles"] == [])

    # Kept: into the row, the small window gone.
    little(f"{sv.BASE}/kept"); time.sleep(1.5)
    little("keep"); time.sleep(0.5)
    st = little("look")
    t.ok("Open in Search moves the page into the row", "127.0.0.1" in st["tabs"] and st["littles"] == [], st)

    # Three windows, each with a page, written down; then a launch made by a
    # small window's link. Every window stays, off screen, and nothing is
    # written out of windows.json — before Open in Search, through a quit
    # without it, and after it.
    for n, name in [(2, "two"), (3, "three")]:
        windows(action="new"); windows(action="front", n=n)
        windows(action="link", url=f"{sv.BASE}/{name}"); time.sleep(1)
    windows(action="front", n=1)
    st = windows()
    t.ok("three windows, each with its page", len(st["windows"]) == 3
         and any(f"{sv.BASE}/two" in w["tabs"] for w in st["windows"])
         and any(f"{sv.BASE}/three" in w["tabs"] for w in st["windows"]), st["windows"])
    sv.quit()
    t.ok("windows.json has all three", len(records()) == 3 and {f"{sv.BASE}/two", f"{sv.BASE}/three"} <= set(kept_rows()), records())
    subprocess.run(["defaults", "write", sv.SUITE, "links.little", "-bool", "true"])

    launch_with(f"{sv.BASE}/linked")
    st = windows()
    t.ok("the link's small window", st["littles"] == [f"{sv.BASE}/linked"], st["littles"])
    t.ok("the browser's windows kept away", st["keptAway"] and all(w["away"] for w in st["windows"]), st["windows"])
    t.ok("none of them closed", not st["closedWindows"], st)
    sv.quit()
    t.ok("quit without them: windows.json still has all three",
         len(records()) == 3 and {f"{sv.BASE}/two", f"{sv.BASE}/three"} <= set(kept_rows()), records())

    launch_with(f"{sv.BASE}/linked")
    little("keep"); time.sleep(1)
    st = windows()
    t.ok("Open in Search brings them all back", not st["keptAway"] and len(st["windows"]) == 3
         and not any(w["away"] for w in st["windows"]), st["windows"])
    t.ok("with the page in the row", any(f"{sv.BASE}/linked" in w["tabs"] for w in st["windows"]), st["windows"])
    sv.quit()
    subprocess.run(["defaults", "write", sv.SUITE, "links.little", "-bool", "false"])
    sv.launch()
    st = windows()
    t.ok("a plain launch after: all three windows, their pages", len(st["windows"]) == 3
         and any(f"{sv.BASE}/two" in w["tabs"] for w in st["windows"])
         and any(f"{sv.BASE}/three" in w["tabs"] for w in st["windows"]), st["windows"])
finally:
    subprocess.run(["pbcopy"], input=saved)
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
