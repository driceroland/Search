#!/usr/bin/env python3
"""Tab groups from one Mac to another over Sync with iCloud (idea 1112), as
two hidden probes: sync already running on both, a group is made on A, A's
own half-minute look puts it up (nothing pokes it), and B reads A's tabs by
group, as History › Tabs on Your Other Devices lists them, without a
relaunch. Then the group renamed, recoloured and a tab moved into it; and A
with every tab in a group.

Build first (`./build.sh`), then `python3 Tests/icloud_groups_two_macs.py`
(about two minutes: it waits for A's timer). CloudKit is never reached: as
in icloud_two_macs.py, each probe runs a Sync with iCloud of its own over a
shared folder (ICloudStandIn.swift). The timer is proven from A's ledger,
read before anything else asks A to publish; "sync" then hands the record to
the folder, as CKSyncEngine sends by itself.
"""
import importlib.util
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


A, B = harness("icloud-ga"), harness("icloud-gb")
t = A.T()
shared = tempfile.mkdtemp(prefix="search-icloud-groups-")


def pair(sv, action, **f): return sv.cmd({"do": "icloudpair", "action": action, **f})
def group(sv, **f): return sv.cmd({"do": "group", **f})
def short(sections): return [(s["group"], [p.rsplit("/", 1)[-1] for p in s["pages"]]) for s in sections]


def mine():
    return short(pair(A, "state")["mine"])


def seen_on_b():
    """What B's menu lists for A, after B fetches what A handed over."""
    pair(A, "sync")
    others = pair(B, "fetch")["others"]
    return [short(o["sections"]) for o in others], others


def wait_for_timer(want, limit=40):
    """A's own look (every 30 s) puts `want` in its record; seconds taken."""
    start = time.time()
    while time.time() - start < limit:
        if mine() == want: return round(time.time() - start)
        time.sleep(1)
    return None


try:
    for sv in (A, B): sv.setup(sidebar=True, **{"tabs.groups": True})
    A.launch(); B.launch()
    a, b = A.page("a"), A.page("b")
    B.page("z")
    pair(A, "start", folder=shared); pair(B, "start", folder=shared)
    lists, _ = seen_on_b()
    t.ok("before: B lists A's two tabs, no group", lists == [[(None, ["a", "b"])]], lists)

    # A group made on A while sync runs: nothing but A's timer sends it.
    group(A, id=a, new=True, name="Work")
    secs = wait_for_timer([("Work", ["a"]), (None, ["b"])])
    t.ok("A's timer puts the new group up within half a minute", secs is not None and secs <= 31, secs)
    lists, others = seen_on_b()
    t.ok("B lists Work with a in it, b loose, no relaunch", lists == [[("Work", ["a"]), (None, ["b"])]], others)

    group(A, name="Work", colour=4)
    secs = None
    start = time.time()
    while time.time() - start < 40:
        pair(A, "sync")
        o = pair(B, "fetch")["others"]
        if o and o[0]["sections"][0]["colour"] == 4: secs = round(time.time() - start); break
        time.sleep(1)
    t.ok("recoloured on A: B has the colour within half a minute", secs is not None, secs)

    # Every tab of A in a group.
    group(A, id=b, name="Work")
    secs = wait_for_timer([("Work", ["a", "b"])])
    t.ok("b moved into Work: up within half a minute", secs is not None, secs)
    lists, others = seen_on_b()
    t.ok("every tab of A in a group: B lists the device and the group", lists == [[("Work", ["a", "b"])]], others)
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
