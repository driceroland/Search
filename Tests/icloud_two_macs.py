#!/usr/bin/env python3
"""Sync with iCloud between two Macs, played by two hidden probes: pin folders
(idea 903) made, renamed, nested, deleted, a pin moved in and out, and pins
that arrive before their folder.

Build first (`./build.sh`), then `python3 Tests/icloud_two_macs.py`. Two test
worlds stand for two Macs, as in sync_two_macs.py (which plays the folder
sync, "Sync with your other Macs"). CloudKit is never reached: each probe's
bench runs a Sync with iCloud of its own over a stand-in that keeps the
records as files in one shared folder (ICloudStandIn.swift), with each Mac's
real pins, folders and rows. Both are started hidden, never shown, and
removed afterwards with the shared folder.
"""
import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent


def harness(name):
    spec = importlib.util.spec_from_file_location(f"sv_{name}", HERE / "split_view.py")
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    mod.use(name)
    return mod


A, B = harness("icloud-a"), harness("icloud-b")
t = A.T()
shared = tempfile.mkdtemp(prefix="search-icloud-")
FIRST = "00000000-0000-0000-0000-000000000001"


def pf(sv, **f): return sv.cmd({"do": "pinfolder", **f})
def pair(sv, action, **f): return sv.cmd({"do": "icloudpair", "action": action, **f})
def folders(sv): return {f["name"]: f["parent"] for f in pf(sv, action="state")["folders"]}
def saved(sv): return {title: folder for title, folder in pf(sv, action="state")["saved"]}
def lines(sv): return [l[:3] for l in pf(sv, action="state")["lines"]]


def a_to_b(only=None):
    pair(A, "sync")
    return pair(B, "fetch", **({"only": only} if only else {}))


try:
    A.setup(sidebar=True)
    # B shows pinned rows but has Folders in pinned rows off (it doesn't sync).
    B.setup(sidebar=True, **{"pins.list": True, "pins.folders": False})
    A.launch(); B.launch()

    # On A: two pinned rows, "a" in a folder Work, "b" loose.
    pf(A, action="on")
    a, b = A.page("a"), A.page("b")
    for id in (a, b): pf(A, action="pin", id=id)
    pf(A, action="new", name="Work", id=a)
    t.ok("A: a is in Work", saved(A).get("a") == "Work", saved(A))

    st = pair(A, "start", folder=shared)
    t.ok("A joins and puts up its folders", f"pinfolders.{FIRST}" in st["sent"], st)
    st = pair(B, "start", folder=shared)
    t.ok("B joins", st["joined"], st)

    s = pf(B, action="state")
    t.ok("B has A's folder, though it draws none", list(folders(B)) == ["Work"] and s["setting"] is False, s["folders"])
    t.ok("B: a is filed in Work", saved(B).get("a") == "Work", saved(B))
    t.ok("B: b is loose", saved(B).get("b") is None, saved(B))
    t.ok("B with folders off: no folder drawn, the rows flat", s["drawsFolders"] is False, s)
    pf(B, action="on")
    s = pf(B, action="state")
    t.ok("B turns folders on: a is drawn inside Work",
         s["drawsFolders"] and ["folder", 0, "Work"] in lines(B) and ["pin", 1, "a"] in lines(B), s)

    pf(A, action="rename", name="Work", to="Office")
    a_to_b()
    t.ok("renamed on A, renamed on B", list(folders(B)) == ["Office"], folders(B))

    pf(A, action="new", name="Docs", **{"in": "Office"})
    pf(A, action="move", id=b, folder="Docs")
    a_to_b()
    t.ok("a folder made inside another on A: nested on B", folders(B).get("Docs") == "Office", folders(B))
    t.ok("b moved into Docs on A: in Docs on B", saved(B).get("b") == "Docs", saved(B))

    pf(A, action="move", id=b, folder="none")
    a_to_b()
    t.ok("b moved out on A: loose on B", saved(B).get("b") is None and "b" in saved(B), saved(B))

    pf(A, action="nest", name="Docs", parent="none")
    a_to_b()
    t.ok("Docs taken to the top on A: at the top on B", "Docs" in folders(B) and folders(B)["Docs"] is None, folders(B))

    pf(A, action="delete", name="Docs")
    a_to_b()
    t.ok("Docs deleted on A: gone on B", list(folders(B)) == ["Office"], folders(B))
    t.ok("…and no pin lost", sorted(saved(B)) == ["a", "b"], saved(B))

    # Pins before their folder: the folder's record held back.
    pf(A, action="new", name="Later", id=b)
    a_to_b(only="pins.")
    t.ok("pins first: b is still here", "b" in saved(B), saved(B))
    t.ok("…drawn at the top of the rows while its folder isn't here", ["pin", 0, "b"] in lines(B) and "Later" not in folders(B), lines(B))
    # Meanwhile B keeps b's folder's id, and puts nothing of the folder up.
    on_disk = json.load(open(f"{B.SUPPORT}/pins.json"))[FIRST]
    t.ok("…its folder's id kept on B", any(d["title"] == "b" and d.get("folder") for d in on_disk), on_disk)
    st = pair(B, "sync")
    t.ok("…and B writes no folders over A's", f"pinfolders.{FIRST}" not in st["sent"], st["sent"])
    st = pair(B, "fetch")
    t.ok("the folder comes: b is in it", saved(B).get("b") == "Later" and "Later" in folders(B), (folders(B), saved(B)))
    t.ok("…and drawn inside it", ["pin", 1, "b"] in lines(B), lines(B))

    # And the other way: B renames, A follows.
    pf(B, action="rename", name="Later", to="Later on B")
    pair(B, "sync")
    pair(A, "fetch")
    t.ok("renamed on B, renamed on A", "Later on B" in folders(A), folders(A))
    t.ok("A's pin still in it", saved(A).get("b") == "Later on B", saved(A))
finally:
    t.done()
    for sv in (A, B):
        try: pair(sv, "stop")
        except Exception as e: print("stop:", e)
        try: sv.finish()
        except Exception as e: print("finish:", e)
        subprocess.run(["defaults", "delete", sv.SUITE], capture_output=True)
    shutil.rmtree(shared, ignore_errors=True)
sys.exit(1 if t.failed else 0)
