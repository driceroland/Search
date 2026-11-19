#!/usr/bin/env python3
"""The tabs folded away with ⌘S stay folded across a quit (idea 738), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/fold_keep.py`. It uses the
split suite's harness: started hidden, nothing brought forward, everything
removed afterwards. Each window's fold is written down with it in
windows.json and comes back at the next launch: the column folded, quit,
relaunched, still folded; unfolded, relaunched, shown; the strip across the
top the same. With two windows each keeps its own; a new window (⌘N) folds
as the one in front, and a closed window brought back with ⇧⌘T comes back as
it was. A line written before the fold was kept loads shown, and Settings'
hide-until-the-edge still folds the column at launch whatever was saved.
"""
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("fold-keep")

t = sv.T()
def windows(action="list", **f): return sv.cmd({"do": "windows", "action": action, **f})["windows"]
def folds(): return [w["folded"] for w in windows()]
def fold(on, n=1): sv.cmd({"do": "ui", "folded": on, "window": n}); time.sleep(0.3)
def saved(): return [r.get("folded") for r in json.load(open(f"{sv.SUPPORT}/windows.json"))]
def relaunch():
    sv.quit(); time.sleep(0.5)
    kept = saved()
    sv.launch(); time.sleep(1)
    return kept

try:
    sv.setup(); sv.launch()
    sv.page("a")

    # One window, the column.
    t.ok("starts shown", folds() == [False], folds())
    fold(True)
    kept = relaunch()
    t.ok("folded: written down at quit", kept == [True], kept)
    t.ok("folded: still folded after a relaunch", folds() == [True], folds())
    kept = relaunch()
    t.ok("folded: still folded after a second relaunch", folds() == [True], (folds(), kept))
    fold(False)
    kept = relaunch()
    t.ok("unfolded: nothing written", kept == [None], kept)
    t.ok("unfolded: shown after a relaunch", folds() == [False], folds())

    # The strip across the top folds and stays folded the same way.
    sv.cmd({"do": "ui", "sidebar": False}); time.sleep(0.5)
    fold(True)
    relaunch()
    t.ok("strip: still folded after a relaunch", folds() == [True], folds())
    # Back to the column: the tabs come out, as a change of layout always did.
    sv.cmd({"do": "ui", "sidebar": True}); time.sleep(0.5)
    t.ok("strip to column: the column comes out", folds() == [False], folds())
    relaunch()
    t.ok("strip to column: shown after a relaunch", folds() == [False], folds())

    # Two windows, each its own.
    windows("new"); time.sleep(0.5)
    t.ok("two windows: the new one from a shown window is shown", folds() == [False, False], folds())
    fold(True, n=2)
    kept = relaunch()
    t.ok("two windows: only the second written folded", kept == [None, True], kept)
    t.ok("two windows: the first shown, the second folded after a relaunch", folds() == [False, True], folds())

    # ⌘N from the folded window: folded too, as in Safari and Arc.
    windows("front", n=2)
    windows("new"); time.sleep(0.5)
    t.ok("⌘N from a folded window: folded too", folds() == [False, True, True], folds())
    windows("front", n=1)
    windows("new"); time.sleep(0.5)
    t.ok("⌘N from a shown window: shown", folds() == [False, True, True, False], folds())

    # ⇧⌘T brings a closed folded window back folded.
    windows("close", n=3); time.sleep(0.5)
    windows("reopen"); time.sleep(0.5)
    t.ok("⇧⌘T: the closed folded window comes back folded", folds() == [False, True, False, True], folds())
    for n in (4, 3, 2): windows("close", n=n); time.sleep(0.4)
    relaunch()

    # A line from before the fold was kept: shown.
    fold(True)
    sv.quit(); time.sleep(0.5)
    path = f"{sv.SUPPORT}/windows.json"
    lines = json.load(open(path))
    for r in lines: r.pop("folded", None)
    json.dump(lines, open(path, "w"))
    sv.launch(); time.sleep(1)
    t.ok("an old line without the fold: shown", folds() == [False], folds())

    # Hide the column until the pointer reaches the edge: folded at launch,
    # as before, whatever the window last had.
    sv.quit(); time.sleep(0.5)
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.hides", "-bool", "true"])
    sv.launch(); time.sleep(1)
    t.ok("hides until the edge: folded at launch", folds() == [True], folds())
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
