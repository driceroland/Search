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
    t.ok("on by default (25 Nov 2026)", st.get("setting") is True, st.get("setting"))
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
    # A folder's row is as tall as a pin's beside it, normal and roomier.
    for roomy in (False, True):
        d = pf(action="drawn", roomy=roomy)
        hs = d.get("heights") or []
        folders_h = {h[2] for h in hs if h[0] == "folder"}
        pins_h = {h[2] for h in hs if h[0] == "pin"}
        mode = "roomier" if roomy else "normal"
        t.ok(f"{mode}: a folder row is as tall as a tab row ({d.get('row')})",
             folders_h == pins_h == {d.get("row")}, hs)
    pf(action="drawn", roomy=False)
    # A folder carried by its heading: out of its folder, reordered, back in.
    def tops(st): return [x[2] for x in st.get("lines") or [] if x[0] == "folder" and x[1] == 0]
    st = pf(action="carry", name="Docs", over=c)
    parent = {f["name"]: f["parent"] for f in st["folders"]}
    t.ok("carried over a pin at the top: Docs out of Work", parent.get("Docs") is None, st.get("place"))
    t.ok("…after the top's folders", tops(st) == ["Work", "Docs"], tops(st))
    st = pf(action="carry", name="Docs", at="above")
    t.ok("carried above every line: Docs first", tops(st) == ["Docs", "Work"], tops(st))
    st = pf(action="carry", name="Work", over="Docs", part="top")
    t.ok("carried onto the top of Docs's heading: Work before it", tops(st) == ["Work", "Docs"], tops(st))
    st = pf(action="carry", name="Work", over="Docs")
    parent = {f["name"]: f["parent"] for f in st["folders"]}
    t.ok("carried onto the middle of Docs's heading: Work into Docs", parent.get("Work") == "Docs", st.get("place"))
    st = pf(action="carry", name="Docs", over=b)
    parent = {f["name"]: f["parent"] for f in st["folders"]}
    t.ok("never into a folder inside itself", parent.get("Docs") is None and st.get("place") is None, st.get("place"))
    st = pf(action="carry", name="Work", at="below")
    st = pf(action="carry", name="Docs", over="Work")
    parent = {f["name"]: f["parent"] for f in st["folders"]}
    t.ok("…and back: Docs into Work", parent.get("Docs") == "Work" and parent.get("Work") is None, parent)
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
