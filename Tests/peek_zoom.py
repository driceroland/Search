#!/usr/bin/env python3
"""A peek opens at the page zoom from Settings, or the site's own (#691).

Build first (`./build.sh`), then `python3 Tests/peek_zoom.py`. It uses the
split suite's harness: started hidden, no window made or shown, everything
removed afterwards.
"""
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bug-peek-zoom")
t = sv.T()
OTHER = sv.BASE.replace("127.0.0.1", "localhost")

def peek_zoom(within=6):
    end = time.time() + within
    while time.time() < end:
        p = sv.cmd({"do": "probe"})
        if p.get("peek") and p.get("peekZoom", 0) and abs(p["peekZoom"] - 1) > 0.001:
            return p["peekZoom"]
        time.sleep(0.2)
    return sv.cmd({"do": "probe"}).get("peekZoom")

try:
    sv.setup()
    subprocess.run(["defaults", "write", sv.SUITE, "pageZoom", "-float", "1.25"])
    sv.launch()
    a = sv.page("home"); sv.sp("select", id=a); time.sleep(0.5)

    sv.cmd({"do": "peek", "url": f"{sv.BASE}/peeked"})
    z = peek_zoom()
    t.ok("a peek opens at the default zoom from Settings", z is not None and abs(z - 1.25) < 0.01, z)
    sv.cmd({"do": "peek", "url": "close"}); time.sleep(0.5)

    # A site with a zoom of its own keeps it in a peek, as in a tab.
    subprocess.run(["defaults", "write", sv.SUITE, "zoom.localhost", "-float", "0.9"])
    sv.cmd({"do": "peek", "url": f"{OTHER}/own"})
    z = peek_zoom()
    t.ok("a peek opens at the site's own zoom", z is not None and abs(z - 0.9) < 0.01, z)
    sv.cmd({"do": "peek", "url": "close"}); time.sleep(0.5)
finally:
    sv.finish()
t.done()
sys.exit(1 if t.failed else 0)
