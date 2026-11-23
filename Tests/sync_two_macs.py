#!/usr/bin/env python3
"""Sync with your other Macs, played by two hidden probes sharing one folder:
pins, and pin folders made, renamed, nested, a pin moved in and out, a
folder deleted, and a pin item from an older Search (no folder in it) that
must not take a pin out of its folder.

Build first (`./build.sh`), then `python3 Tests/sync_two_macs.py`. Two test
worlds stand for two Macs; both are started hidden, never shown, and removed
afterwards with the shared folder.
"""
import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent


def harness(name):
    spec = importlib.util.spec_from_file_location(f"sv_{name}", HERE / "split_view.py")
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    mod.use(name)
    return mod


A, B = harness("sync-a"), harness("sync-b")
t = A.T()
shared = tempfile.mkdtemp(prefix="search-sync-")


def homes(sv):
    try: return [p.get("home") for p in json.load(open(f"{sv.SUPPORT}/pins.json")).get(FIRST, [])]
    except Exception: return []


FIRST = "00000000-0000-0000-0000-000000000001"


def pf(sv, **f): return sv.cmd({"do": "pinfolder", **f})
def folders(sv): return {f["name"]: f["parent"] for f in pf(sv, action="state")["folders"]}
def saved(sv): return {title: folder for title, folder in pf(sv, action="state")["saved"]}
def names(sv): return {short: name for short, name, _ in pf(sv, action="state")["order"]}


def wait(cond, within=12):
    end = time.time() + within
    while time.time() < end:
        if cond(): return True
        time.sleep(0.5)
    return cond()


try:
    for sv in (A, B):
        sv.setup(sidebar=True)
        subprocess.run(["defaults", "write", sv.SUITE, "sync.folder", shared])
    A.launch(); B.launch()

    # Pin folders, on both.
    pf(A, action="on"); pf(B, action="on")
    a, b = A.page("a"), A.page("b")
    for id in (a, b): pf(A, action="pin", id=id)
    t.ok("B gets A's two pinned rows", wait(lambda: sorted(saved(B)) == ["a", "b"]), saved(B))
    pf(A, action="new", name="Work", id=a)
    t.ok("a folder made on A, with a in it: on B", wait(lambda: list(folders(B)) == ["Work"]), folders(B))
    t.ok("…a is filed in it on B", wait(lambda: saved(B).get("a") == "Work"), saved(B))
    t.ok("…and b is loose", saved(B).get("b") is None, saved(B))
    pf(B, action="fold", name="Work")
    pf(A, action="rename", name="Work", to="Office")
    t.ok("renamed on A: renamed on B", wait(lambda: list(folders(B)) == ["Office"]), folders(B))
    fold = lambda sv: {f["name"]: f["collapsed"] for f in pf(sv, action="state")["folders"]}
    t.ok("folding stays on each Mac", fold(B).get("Office") is True and fold(A).get("Office") is False, (fold(A), fold(B)))
    pf(A, action="new", name="Docs", **{"in": "Office"})
    t.ok("a folder made inside another on A: nested on B", wait(lambda: folders(B).get("Docs") == "Office"), folders(B))
    pf(A, action="move", id=b, folder="Docs")
    t.ok("b moved into Docs on A: in Docs on B", wait(lambda: saved(B).get("b") == "Docs"), saved(B))
    pf(A, action="move", id=b, folder="none")
    t.ok("b moved out on A: loose on B", wait(lambda: "b" in saved(B) and saved(B)["b"] is None), saved(B))
    pf(A, action="nest", name="Docs", parent="none")
    t.ok("Docs taken to the top on A: at the top on B", wait(lambda: "Docs" in folders(B) and folders(B)["Docs"] is None), folders(B))
    pf(A, action="move", id=b, folder="Docs")
    wait(lambda: saved(B).get("b") == "Docs")
    pf(A, action="delete", name="Docs")
    t.ok("Docs deleted on A: gone on B", wait(lambda: list(folders(B)) == ["Office"]), folders(B))
    t.ok("…its pin loose again, none lost", wait(lambda: saved(B) == {"a": "Office", "b": None}), saved(B))
    pf(B, action="rename", name="Office", to="Office on B")
    t.ok("renamed on B: renamed on A", wait(lambda: list(folders(A)) == ["Office on B"]), folders(A))
    t.ok("…A's pin still in it", saved(A).get("a") == "Office on B", saved(A))

    # A Search from before pin folders synced (1.0.16) edits pin a: its item
    # has no folder in it, and its file none of the folder items.
    scope = next(p for p in Path(shared, "Search Sync").iterdir() if p.name.startswith("profile-"))
    mine = json.load(open(next(p for p in scope.glob("*.json"))))
    a_id = next(d["id"] for d in json.load(open(f"{A.SUPPORT}/pins.json"))[FIRST] if d["title"] == "a")
    key = f"pin:{FIRST}:{a_id}"
    items = {k: v for k, v in mine["items"].items() if not k.startswith(("pinfolder", "infolder:"))}
    old_pin = json.loads(items[key]["v"])
    t.ok("a pin item is as 1.0.16 wrote it: no folder in it", "folder" not in old_pin, old_pin)
    old_pin["name"] = "Renamed on an older Mac"
    items[key] = {"v": json.dumps(old_pin, sort_keys=True, separators=(",", ":")), "t": time.time() + 5, "d": "OLDMAC"}
    (scope / "OLDMAC.json").write_text(json.dumps({"format": 1, "device": "OLDMAC", "name": "Older Mac", "scope": scope.name,
                                                   "written": time.time(), "items": items}))
    b_short = next(short for short, name in names(B).items() if name == "a")
    t.ok("B takes the older Mac's edit", wait(lambda: names(B).get(b_short) == "Renamed on an older Mac"), names(B))
    t.ok("…and a stays in its folder on B", saved(B).get("a") == "Office on B", saved(B))
    t.ok("…and on A", wait(lambda: any(n == "Renamed on an older Mac" for n in names(A).values())) and saved(A).get("a") == "Office on B", saved(A))
    (scope / "OLDMAC.json").unlink()

    c = A.page("c")
    A.cmd({"do": "pin", "id": c}); A.sp("save")
    home = f"{A.BASE}/c"
    t.ok("A writes its file in the shared folder", wait(lambda: any(Path(shared).rglob("*.json"))), list(Path(shared).rglob("*")))
    t.ok("B gets A's new pin", wait(lambda: home in homes(B)), homes(B))
    # A broken file from a third Mac changes nothing.
    some = next(Path(shared).rglob("*.json")).parent
    (some / "BROKEN.json").write_text("{not json")
    before = sorted(homes(A))
    time.sleep(4)
    t.ok("a broken file is ignored", sorted(homes(A)) == before, homes(A))
finally:
    t.done()
    for sv in (A, B):
        try: sv.finish()
        except Exception as e: print("finish:", e)
        subprocess.run(["defaults", "delete", sv.SUITE], capture_output=True)
    shutil.rmtree(shared, ignore_errors=True)
sys.exit(1 if t.failed else 0)
