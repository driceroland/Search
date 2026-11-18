#!/usr/bin/env python3
"""Sync with iCloud is off until turned on, and while off nothing of it runs
(ICloudSync.swift), in a hidden probe.

Build first (`./build.sh debug`), then `python3 Tests/icloud_sync_off.py`.
It uses split_view.py's harness: started hidden in a world of its own,
driven through ./bench's socket, everything removed afterwards.

CloudKit is never reached from here: a test run can't turn iCloud sync on
(ICloudSync.available is false in every SEARCH_PROBE run), and this checks
that it can't. The rules themselves (merge, latest wins, no echo, what
never goes up) are Tests/SearchTests/ICloudSyncTests.swift, against a
stand-in engine.
"""
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("icloud-off")

t = sv.T()
def state(**extra): return sv.cmd({"do": "icloud", **extra})
try:
    sv.setup(); sv.launch()
    s = state()
    t.ok("off on a first launch", s["on"] is False, s)
    t.ok("nothing running, waiting or listening", (s["scheduled"], s["engine"]) == (False, False), s)
    t.ok("nothing written: no setting, no file", (s["stored"], s["file"]) == (False, False), s)
    t.ok("a test run can't reach CloudKit", s["available"] is False, s)
    # A build signed with a profile that carries iCloud says so; any other
    # build is right to say no. Either way it launched, which a signature
    # the profile doesn't cover would not have.
    signed = "iCloud.com.officecommun.search" in subprocess.run(
        ["codesign", "-d", "--entitlements", ":-", sv.APP], capture_output=True, text=True).stdout
    t.ok("the signature's iCloud entitlement is seen from inside", s["entitled"] is signed, (s["entitled"], signed))
    t.ok("Settings says why", s["summary"] == ("Off in a test run" if signed else "Needs a build of Search signed for iCloud"), s["summary"])
    s = state(turn="on")
    t.ok("asked to turn on, a test run stays off", (s["on"], s["scheduled"], s["stored"]) == (False, False, False), s)
    found = [f["id"] for f in sv.cmd({"do": "settings", "find": "icloud"})["found"]]
    t.ok("Find a setting finds it", "icloud" in found, found)
    found = [f["id"] for f in sv.cmd({"do": "settings", "find": "iphone"})["found"]]
    t.ok("by iPhone too", "icloud" in found, found)
    items = {i["id"]: i for i in sv.cmd({"do": "settings"})["items"]}
    t.ok("in Settings › General, after the folder sync",
         (items["icloud"]["page"], items["icloud"]["group"]) == (items["sync"]["page"], items["sync"]["group"]),
         items.get("icloud"))
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
