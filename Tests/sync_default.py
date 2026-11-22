#!/usr/bin/env python3
"""Sync with iCloud and Handoff on for a new install, after the welcome, and
left alone for one from before, which the What's New card offers them to
first (SyncDefault.swift), in hidden probes.

Build first (`./build.sh debug`), then `python3 Tests/sync_default.py`.
It uses split_view.py's harness: started hidden in a world of its own,
driven through ./bench's socket, everything removed afterwards.

CloudKit is never reached: a test run can't (ICloudSync.available is false
in every SEARCH_PROBE run), so "on" here is the choice kept, waiting, with
nothing running. What syncs once it runs is ICloudSyncTests and
icloud_two_macs.py.
"""
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("sync-default")

t = sv.T()
def state(**extra): return sv.cmd({"do": "icloud", **extra})
def nothing_runs(s): return (s["on"], s["stored"], s["scheduled"], s["engine"], s["file"]) == (False, False, False, False, False)
WAITS = ("Needs a build of Search signed for iCloud", "Off in a test run")
try:
    # A new install: no line at all but the bench's.
    sv.setup()
    subprocess.run(["defaults", "delete", sv.SUITE, "welcomed"], capture_output=True)
    sv.launch()
    s = state()
    t.ok("a fresh world is a new install", s["new"] is True, s)
    t.ok("the welcome is up, both switches on", s["welcoming"] and s["starts"] == {"sync": True, "handoff": True}, s)
    t.ok("nothing syncs while the welcome is up", nothing_runs(s), s)
    t.ok("nothing handed off while the welcome is up", (s["handoff"], s["handoffStored"], s["offered"]) == (False, False, False), s)

    # Quit during the welcome: nothing has happened, and it comes back.
    sv.quit(); sv.launch()
    s = state()
    t.ok("quit during the welcome: still new, the welcome again", s["new"] and s["welcoming"], s)
    t.ok("quit during the welcome: nothing synced", nothing_runs(s), s)
    t.ok("quit during the welcome: Handoff still off", (s["handoff"], s["handoffStored"]) == (False, False), s)

    # The welcome left as it started.
    s = state(leave=True)
    t.ok("past the welcome, sync is on", (s["on"], s["stored"], s["welcoming"]) == (True, True, False), s)
    t.ok("and Handoff", s["handoff"] is True, s)
    t.ok("without iCloud it waits: no engine, no timer", (s["scheduled"], s["engine"]) == (False, False), s)
    t.ok("Settings says why", s["summary"] in WAITS, s["summary"])
    sv.quit(); sv.launch()
    s = state()
    t.ok("next launch: no welcome, both still on, still new", (s["welcoming"], s["on"], s["handoff"], s["new"]) == (False, True, True, True), s)

    # A new install that turns both off in the welcome.
    sv.setup()
    subprocess.run(["defaults", "delete", sv.SUITE, "welcomed"], capture_output=True)
    sv.launch()
    s = state(leave=True, sync=False, handoff=False)
    t.ok("both turned off in the welcome stay off", nothing_runs(s) and s["handoff"] is False and not s["welcoming"], s)

    # An install from before, sync off: nothing changes on its own.
    sv.setup(**{"passkeys.for": True})
    sv.launch()
    s = state()
    t.ok("a world from before is existing", s["new"] is False and not s["welcoming"], s)
    t.ok("its sync stays off", nothing_runs(s), s)
    t.ok("its Handoff stays off", (s["handoff"], s["handoffStored"]) == (False, False), s)
    rows = sv.cmd({"do": "news", "rows": True})
    t.ok("the card offers Sync with iCloud first, then Handoff",
         rows["first"][:2] == ["Sync with iCloud", "Handoff to your iPhone"], rows)
    t.ok("and not again under earlier versions",
         not {"Sync with iCloud", "Handoff to your iPhone"} & set(rows["earlier"]), rows["earlier"])
    shot = "/private/tmp/claude-501/syncdef-shots/card-probe.png"
    t.ok("the card drawn off screen", "saved" in sv.cmd({"do": "news", "path": shot}), shot)
    sv.quit(); sv.launch()
    s = state()
    t.ok("next launch: still off", nothing_runs(s) and s["handoff"] is False, s)

    # An install from before, sync on: stays on, and the card doesn't ask.
    sv.setup(**{"passkeys.for": True, "icloud.sync": True, "handoff": True})
    sv.launch()
    s = state()
    t.ok("existing with sync on stays on", (s["new"], s["on"], s["stored"], s["handoff"]) == (False, True, True, True), s)
    rows = sv.cmd({"do": "news", "rows": True})
    t.ok("the card doesn't offer what is on",
         not {"Sync with iCloud", "Handoff to your iPhone"} & set(rows["first"] + rows["earlier"]), rows)
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
