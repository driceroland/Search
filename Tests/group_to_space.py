#!/usr/bin/env python3
"""Move Group to Space, and ⌃Tab's switcher on a key of its own, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/group_to_space.py`.

A group's menu › Move Group to Space takes every tab of the group, in its
order, into the other space, where it is the same group, folded as it was;
the space it left keeps its other tabs, with one of them in front. The
space it went to has it in its file, so it is still there after ⌘Q and a
relaunch.

Then Settings › Shortcuts gives the recent-tabs switcher ⌥E instead of
⌃Tab (as the store writes it): ⌥E brings the switcher up, letting go of ⌥
takes the tab, and ⌃Tab no longer does.

Nothing here makes, shows or brings forward a window.
"""
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("hub-va-group")


def space(**f): return sv.cmd({"do": "space", **f})


def group(**f): return sv.cmd({"do": "group", **f})


def ids(): return {s["name"]: s["id"] for s in json.load(open(f"{sv.SUPPORT}/spaces.json"))}


def main():
    t = sv.T()
    try:
        sv.setup(**{"spaces": True, "tabs.groups": True})
        sv.launch()
        space(action="new", name="Two")
        space(action="go", index=1); time.sleep(0.6)
        a, b, c = (sv.page(n) for n in ("alpha", "beta", "gamma"))
        stay = sv.page("stays")
        group(id=a, new=True, name="Folder")
        for p in (b, c): group(id=p, name="Folder")
        # In front, then folded: going to a tab in a folded group opens it.
        sv.sp("select", id=b); time.sleep(0.3)
        group(name="Folder", fold=True)
        r = sv.cmd({"do": "tospace", "group": "Folder", "index": 2}); time.sleep(0.8)
        st = sv.sp("state")
        t.ok("the group left this space, its three tabs with it",
             "Folder" not in r["groups"] and not {a, b, c} & set(r["tabs"]), r)
        t.ok("a tab that stayed is in front, the one after the group",
             st["activeID"] not in (a, b, c) and st["activeID"] in [x["id"] for x in st["tabs"]]
             and stay in [x["id"] for x in st["tabs"]], (st["activeID"], [x["id"] for x in st["tabs"]]))
        shape = json.load(open(f"{sv.SUPPORT}/session-{ids()['Two']}.json"))
        groups = {g["id"]: g for g in shape.get("groups") or []}
        inside = [e["url"].rsplit("/", 1)[-1] for e in shape["tabs"] if e.get("groupID") in groups]
        t.ok("the other space's file has the group, folded, with the three in order",
             [g["name"] for g in groups.values()] == ["Folder"] and all(g["collapsed"] for g in groups.values())
             and inside == ["alpha", "beta", "gamma"], shape)
        space(action="go", index=2); time.sleep(0.8)
        g = group()
        t.ok("gone there: one group, folded, with its three tabs",
             [(x["name"], x["collapsed"], len(x["tabs"])) for x in g["groups"]] == [("Folder", True, 3)], g)
        sv.quit(); time.sleep(1); sv.launch(); time.sleep(1)
        space(action="go", index=2); time.sleep(0.8)
        g = group()
        t.ok("after a relaunch, still there", [(x["name"], len(x["tabs"])) for x in g["groups"]] == [("Folder", 3)], g)
        sv.quit(); time.sleep(1)

        # ⌃Tab's switcher on ⌥E.
        shortcuts = json.dumps({"tabs.recent": {"key": {"key": "e", "command": False, "shift": False,
                                                        "option": True, "control": False}}})
        subprocess.run(["defaults", "write", sv.SUITE, "shortcuts", "-data",
                        shortcuts.encode().hex()], check=True)
        sv.launch(); time.sleep(1)
        space(action="go", index=1); time.sleep(0.6)
        x, y = sv.page("one"), sv.page("two")
        sv.sp("select", id=x); time.sleep(0.3)
        sv.sp("select", id=y); time.sleep(0.3)
        sv.cmd({"do": "press", "code": 14, "chars": "e", "mods": ["opt"]}); time.sleep(0.8)
        s = sv.cmd({"do": "switcher"})
        t.ok("⌥E brings the switcher up", s.get("visible"), s)
        sv.cmd({"do": "press", "code": 14, "chars": "e", "mods": ["opt"], "letgo": True}); time.sleep(0.8)
        s = sv.cmd({"do": "switcher"})
        t.ok("letting go of ⌥ takes the tab picked", not s.get("visible") and s.get("active") not in (None, y), s)
        sv.cmd({"do": "press", "code": 48, "chars": "\t", "mods": ["ctrl"]}); time.sleep(0.8)
        s = sv.cmd({"do": "switcher"})
        t.ok("⌃Tab no longer brings it up", not s.get("visible"), s)
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
