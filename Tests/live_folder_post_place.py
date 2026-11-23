#!/usr/bin/env python3
"""Idea 978: a live folder's post opens among the open tabs, never in a
pinned folder nor in the group of the tab in front, whichever row is in
front and wherever the live folder sits. It came from no page: with a
grouped tab in front it went into that group.

Build first (`./build.sh`), then `python3 Tests/live_folder_post_place.py`.
The feed is split_view.py's own local server; nothing leaves the Mac and
nothing is shown.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("live-post-place")
t = sv.T()


def pf(**f): return sv.cmd({"do": "pinfolder", **f})


def tabs(): return sv.cmd({"do": "tabs"})["tabs"]


def check(label, before_ids):
    st = pf(action="openitem", name="Probe Feed", title="Post 2")
    time.sleep(0.5)
    now = tabs()
    new = [x for x in now if x["id"] not in before_ids]
    st = pf(action="state")
    rows = [r[0] for r in st.get("order") or []]
    in_folder = [r for r in st.get("order") or [] if r[2] is not None]
    drawn = [str(x) for x in st.get("lines") or []]
    ok = (len(new) == 1 and new[0]["id"] not in rows and new[0]["active"]
          and not any(new[0]["id"] in x for x in drawn) and len(in_folder) == 1)
    t.ok(f"{label}: the post is an open tab, not a row in a folder", ok,
         {"new": new, "order": st.get("order"), "lines": drawn})
    return now


try:
    sv.setup(sidebar=True); sv.launch()
    a = sv.page("a"); b = sv.page("b"); sv.page("front")
    pf(action="on")
    pf(action="pin", id=a); pf(action="pin", id=b)
    pf(action="new", name="Work", id=a)
    pf(action="live", url=f"{sv.BASE}/blog")
    ids = {x["id"] for x in tabs()}

    # The pinned folder's tab in front, the live folder below it.
    sv.cmd({"do": "select", "id": a})
    ids = {x["id"] for x in check("folder's pin in front, live folder below", ids)}
    # A plain tab in front.
    sv.cmd({"do": "select", "id": b})
    ids = {x["id"] for x in check("other pin in front", ids)}
    # The live folder above the pinned folder.
    st = pf(action="carry", name="Probe Feed", at="above")
    sv.cmd({"do": "select", "id": a})
    ids = {x["id"] for x in check("live folder above, folder's pin in front", ids)}
    front = next(x["id"] for x in tabs() if not x["active"] and x["id"] not in (a, b))
    sv.cmd({"do": "select", "id": front})
    ids = {x["id"] for x in check("live folder above, an open tab in front", ids)}
    # A tab in a group in front: the post is not that page's link.
    sv.cmd({"do": "group", "id": front, "new": True, "name": "G"})
    sv.cmd({"do": "select", "id": front})
    now = check("a grouped tab in front", ids)
    new = [x for x in now if x["id"] not in ids]
    t.ok("a grouped tab in front: the post is in no group", new and new[0]["group"] == "", new)
    t.ok("the grouped tab keeps its group", next(x["group"] for x in now if x["id"] == front) == "G", now)
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
