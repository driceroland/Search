#!/usr/bin/env python3
"""Folders in pinned rows, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/pin_folders.py`. Reads the rows the
column lays out (a hidden app draws nothing off screen; PinFoldersTests
draws them); nothing is shown.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("pin-folders")
t = sv.T()


def pf(**f): return sv.cmd({"do": "pinfolder", **f})


try:
    sv.setup(sidebar=True); sv.launch()
    a = sv.page("a"); b = sv.page("b"); c = sv.page("c"); sv.page("front")
    st = pf(action="state")
    t.ok("off by default", st.get("setting") is False, st.get("setting"))
    pf(action="on")
    for id in (a, b, c): pf(action="pin", id=id)
    pf(action="new", name="Work", id=a)
    pf(action="new", name="Docs", **{"in": "Work"})
    pf(action="move", id=b, folder="Docs")
    st = pf(action="state")
    drawn = st.get("lines") or []
    flat = [str(x) for x in drawn]
    print("  drawn:", flat)
    t.ok("Work is drawn, Docs inside it", any("Work" in x for x in flat) and any("Docs" in x for x in flat), flat)
    saved = st.get("saved") or []
    t.ok("pins.json keeps each pin's folder", ["a", "Work"] in saved and ["b", "Docs"] in saved, saved)
    pf(action="fold", name="Work")
    st = pf(action="state"); flat2 = [str(x) for x in st.get("lines") or []]
    t.ok("folded: fewer rows drawn", len(flat2) < len(flat), (flat, flat2))
    pf(action="open", name="Work")
    sv.quit(); sv.launch(); time.sleep(1)
    st = pf(action="state")
    names = [f["name"] for f in st.get("folders", [])]
    t.ok("relaunch: folders kept", "Work" in names and "Docs" in names, names)
    pf(action="delete", name="Docs")
    st = pf(action="state")
    t.ok("delete Docs: b goes up into Work", ["b", "Work"] in (st.get("saved") or []), st.get("saved"))
    pf(action="off")
    st = pf(action="state")
    t.ok("off: the setting is off (the column draws flat rows)", st.get("setting") is False, st.get("setting"))
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
