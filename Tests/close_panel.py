#!/usr/bin/env python3
"""⌘W with a panel up closes the panel, not the tab behind it, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/close_panel.py`. It uses the
split suite's harness: started hidden, everything removed afterwards.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

t = sv.T()
def ids(): return [x["id"] for x in sv.sp("state")["tabs"]]
def cmd_w(): sv.cmd({"do": "press", "code": 13, "chars": "w", "mods": ["cmd"]}); time.sleep(0.6)
try:
    sv.setup(); sv.launch()
    sv.page("a"); sv.page("b")
    for panel, key in [("settings", "settings"), ("history", "history"), ("downloads", "downloads"), ("bookmarks", "bookmarks")]:
        before = ids()
        sv.cmd({"do": "ui", panel: True}); time.sleep(0.5)
        cmd_w()
        up = sv.cmd({"do": "probe"}).get(key)
        t.ok(f"{panel}: ⌘W puts the panel away", up is False or up is None, up)
        t.ok(f"{panel}: the tab behind it stays", ids() == before, (before, ids()))
    before = ids()
    cmd_w()
    t.ok("no panel: ⌘W closes the tab", len(ids()) == len(before) - 1, (before, ids()))
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
