#!/usr/bin/env python3
"""Tab groups in this Mac's open tabs as Sync with iCloud carries them (idea
1093), in one hidden probe: the device record a Mac would write (`icloud`
"published", the same JSON as ICloudSync.publish, CloudKit never reached)
carries each group's name, colour, folded state and its tabs in order; with
no tab in a group, the record is the JSON it was before groups.

Build first (`./build.sh`), then `python3 Tests/icloud_groups.py`. The round
trip between two devices, and a Search from before groups reading the record,
are ICloudSyncTests (`swift test --filter ICloudSyncTests`).
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("icloud-groups")
t = sv.T()


def published(): return json.loads(sv.cmd({"do": "icloud"})["published"])
def group(**f): return sv.cmd({"do": "group", **f})


try:
    sv.setup(sidebar=True, **{"tabs.groups": True}); sv.launch()
    a, b, c, d = sv.page("a"), sv.page("b"), sv.page("c"), sv.page("d")
    group(id=a, new=True, name="Work"); group(id=b, name="Work")
    group(id=c, new=True, name="Read")
    group(name="Work", colour=2); group(name="Work", fold=True)
    sv.sp("select", id=d)
    rec = published()
    names = {g["id"]: g for g in rec.get("groups", [])}
    t.ok("two groups go up", [g["name"] for g in rec.get("groups", [])] == ["Work", "Read"], rec.get("groups"))
    work = next((g for g in rec.get("groups", []) if g["name"] == "Work"), {})
    t.ok("Work: its colour and folded", work.get("colour") == 2 and work.get("collapsed") is True, work)
    by = {p["url"].rsplit("/", 1)[-1]: names.get(p.get("group"), {}).get("name") for p in rec["tabs"]}
    t.ok("each tab names its group, the loose one none", by == {"a": "Work", "b": "Work", "c": "Read", "d": None}, by)
    t.ok("the tabs in the row's order", [p["url"].rsplit("/", 1)[-1] for p in rec["tabs"]] == ["a", "b", "c", "d"], rec["tabs"])

    # Every tab out of its group: the record is the JSON it always was.
    for x in (a, b, c): group(id=x, name="none")
    rec = published()
    t.ok("no group left: no groups in the record", "groups" not in rec, rec)
    t.ok("no group left: no tab names one", all("group" not in p for p in rec["tabs"]) and len(rec["tabs"]) == 4, rec["tabs"])
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
