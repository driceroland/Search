#!/usr/bin/env python3
"""⇧⌘T brings back Search's own pages, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/reopen_own_pages.py` from a
worktree. History, Settings and the rest have no web address, so a closed
one was never remembered: ⇧⌘T right after closing it did nothing, or brought
back an older tab. Kept by its search:// address, it comes back, still one
tab of its kind.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# Its own world, apart from the split suite's in this checkout (see use()).
sv.use("reopen-own-pages")
t = sv.T()


def st(): return sv.sp("state")
def own(s, kind): return [x for x in s["tabs"] if x["internal"].startswith(f"search://{kind}")]


try:
    sv.setup(); sv.launch()
    sv.page("older")
    older = next(x["id"] for x in st()["tabs"] if x["url"].endswith("/older"))
    sv.sp("close", id=older); time.sleep(0.3)
    sv.page("keep")

    # History closed, then ⇧⌘T: History, not the older page.
    h = sv.sp("open", url="search://history")["resultID"]; time.sleep(0.8)
    before = st()["ghosts"]
    sv.sp("close", id=h); time.sleep(0.3)
    s = st()
    t.ok("closed History is remembered", s["ghosts"] == before + 1, (before, s["ghosts"]))
    sv.sp("reopen"); time.sleep(0.8); s = st()
    t.ok("⇧⌘T brings History back", len(own(s, "history")) == 1, [x["internal"] for x in s["tabs"]])
    t.ok("and in front", own(s, "history") and s["activeID"] == own(s, "history")[0]["id"], s["activeID"])
    t.ok("not the older page", not any(x["url"].endswith("/older") for x in s["tabs"]), [x["url"] for x in s["tabs"]])

    # Settings at a section comes back at that section.
    g = sv.sp("open", url="search://settings/privacy")["resultID"]; time.sleep(0.8)
    sv.sp("close", id=g); time.sleep(0.3); sv.sp("reopen"); time.sleep(0.8)
    s = st()
    t.ok("Settings comes back at its section", [x["internal"] for x in own(s, "settings")] == ["search://settings/privacy"],
         [x["internal"] for x in s["tabs"]])

    # Already open again by the time ⇧⌘T: still one tab of its kind.
    sv.sp("close", id=own(st(), "history")[0]["id"]); time.sleep(0.3)
    sv.sp("open", url="search://history"); time.sleep(0.8)
    sv.sp("reopen"); time.sleep(0.8); s = st()
    t.ok("one History tab, not two", len(own(s, "history")) == 1, [x["internal"] for x in s["tabs"]])

    # A Clear took Settings, Settings opened again, Clear undone: one Settings.
    sv.sp("clear"); time.sleep(0.6)
    sv.sp("open", url="search://settings"); time.sleep(0.8)
    sv.sp("reopen"); time.sleep(1); s = st()
    t.ok("clear undone: one Settings tab", len(own(s, "settings")) == 1, [x["internal"] for x in s["tabs"]])
    t.ok("clear undone: the web page back too", any(x["url"].endswith("/keep") for x in s["tabs"]), [x["url"] for x in s["tabs"]])
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
