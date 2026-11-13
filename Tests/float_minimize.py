#!/usr/bin/env python3
"""Minimize on the floating video, off until Settings asks for it.

Build first (`./build.sh`), then `python3 Tests/float_minimize.py`. The
window is opened off every screen and the button is pressed through the
bench.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("float-min")
t = sv.T()
try:
    sv.setup()
    sv.launch()
    up = sv.cmd({"do": "float", "action": "up"})
    t.ok("the window is up, off screen", up.get("showing") is True, up)
    before = sv.cmd({"do": "float"})
    t.ok("minimize is off: no extra button", before.get("buttons") == 5, before)
    offered = sv.cmd({"do": "float", "action": "offer", "on": True})
    t.ok("the setting shows the button", offered.get("buttons") == 6, offered)
    small = sv.cmd({"do": "float", "action": "minimize"})
    t.ok("minimize tucks the window", small["width"] < before["width"] - 40, (before.get("width"), small.get("width")))
    back = sv.cmd({"do": "float", "action": "minimize"})
    t.ok("the same button brings it back", abs(back["width"] - before["width"]) < 8, (before.get("width"), back.get("width")))
    off = sv.cmd({"do": "float", "action": "offer", "on": False})
    t.ok("turning it off hides the button", off.get("buttons") == 5, off)
finally:
    t.done()
    sv.finish()
sys.exit(1 if t.failed else 0)
