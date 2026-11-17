#!/usr/bin/env python3
"""Sync with your other Macs, played by two hidden probes sharing one folder.

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


def spaces(sv):
    try: return [s.get("name") for s in json.load(open(f"{sv.SUPPORT}/spaces.json"))]
    except Exception: return []


def wait(cond, within=12):
    end = time.time() + within
    while time.time() < end:
        if cond(): return True
        time.sleep(0.5)
    return cond()


try:
    for sv in (A, B):
        sv.setup()
        subprocess.run(["defaults", "write", sv.SUITE, "spaces", "-bool", "true"])
        subprocess.run(["defaults", "write", sv.SUITE, "sync.folder", shared])
    A.launch(); B.launch()
    A.page("a")
    A.cmd({"do": "space", "action": "new", "name": "From A"})
    t.ok("A writes its file in the shared folder", wait(lambda: any(Path(shared).rglob("*.json"))), list(Path(shared).rglob("*")))
    t.ok("B gets A's new space", wait(lambda: "From A" in spaces(B)), spaces(B))
    B.cmd({"do": "space", "action": "new", "name": "From B"})
    t.ok("A gets B's new space", wait(lambda: "From B" in spaces(A)), spaces(A))
    t.ok("A keeps its own", "From A" in spaces(A), spaces(A))
    # A broken file from a third Mac changes nothing.
    some = next(Path(shared).rglob("*.json")).parent
    (some / "BROKEN.json").write_text("{not json")
    before = sorted(spaces(A))
    time.sleep(4)
    t.ok("a broken file is ignored", sorted(spaces(A)) == before, spaces(A))
finally:
    t.done()
    for sv in (A, B):
        try: sv.finish()
        except Exception as e: print("finish:", e)
        subprocess.run(["defaults", "delete", sv.SUITE], capture_output=True)
    shutil.rmtree(shared, ignore_errors=True)
sys.exit(1 if t.failed else 0)
