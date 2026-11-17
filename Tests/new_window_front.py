#!/usr/bin/env python3
"""A window just opened is the one in front (#1146), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/new_window_front.py`.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("new-window-front")
t = sv.T()
try:
    sv.setup(); sv.launch()
    sv.page("a")
    st = sv.cmd({"do": "windows", "action": "new"})
    ws = st["windows"]
    t.ok("two windows", len(ws) == 2, ws)
    t.ok("the new one is in front, with no click", len(ws) == 2 and ws[1]["front"] and not ws[0]["front"], [(w["n"], w["front"]) for w in ws])
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
