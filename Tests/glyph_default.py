#!/usr/bin/env python3
"""Tabs and pins show the site's icon by default (Glyph.standard), in hidden
probes: a new install, one from before that never chose, one that chose
letters. The default is never written, and who sees the welcome is as it was
(a saved "glyph" still counts as a session from before it).

Build first (`./build.sh`), then `python3 Tests/glyph_default.py`. It uses
split_view.py's harness: started hidden in a world of its own, read through
./bench's socket, everything removed afterwards.
"""
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("glyph-default")
t = sv.T()
def glyph(): return sv.cmd({"do": "settings", "find": "favicon"})["values"].get("glyph")
def stored():
    r = subprocess.run(["defaults", "read", sv.SUITE, "glyph"], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None
def welcoming(): return sv.cmd({"do": "icloud"}).get("welcoming")

try:
    sv.setup()
    subprocess.run(["defaults", "delete", sv.SUITE, "welcomed"], capture_output=True)
    sv.launch()
    t.ok("new install: site icons", glyph() == "icons", glyph())
    t.ok("new install: the default is never written", stored() is None, stored())
    t.ok("new install: the welcome is up", welcoming() is True, welcoming())
    sv.quit()

    sv.setup()
    subprocess.run(["defaults", "write", sv.SUITE, "welcomed", "-bool", "true"])
    subprocess.run(["defaults", "delete", sv.SUITE, "glyph"], capture_output=True)
    sv.launch()
    t.ok("from before, never chose: site icons", glyph() == "icons", glyph())
    t.ok("from before: no welcome", welcoming() is False, welcoming())
    t.ok("from before: nothing written", stored() is None, stored())
    sv.quit()

    sv.setup()
    subprocess.run(["defaults", "write", sv.SUITE, "glyph", "-string", "letters"])
    subprocess.run(["defaults", "delete", sv.SUITE, "welcomed"], capture_output=True)
    sv.launch()
    t.ok("chose letters: letters stay", glyph() == "letters", glyph())
    t.ok("a chosen glyph still counts as from before the welcome", welcoming() is False, welcoming())
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
