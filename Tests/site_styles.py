#!/usr/bin/env python3
"""A site's own CSS, in a hidden probe: it colors the page, and only that site.

Build first (`./build.sh`), then `python3 Tests/site_styles.py`. The world
is wiped afterwards. The sheet is written into the world's folder before
launch, the way Save would leave it.
"""
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("style-tests")
t = sv.T()

try:
    sv.setup(**{"styles.sites": True})
    os.makedirs(sv.SUPPORT, exist_ok=True)
    with open(f"{sv.SUPPORT}/styles.json", "w") as fh:
        json.dump({"127.0.0.1": "p { color: rgb(1, 2, 3) }"}, fh)
    sv.launch()
    opened = sv.cmd({"do": "open", "url": f"{sv.BASE}/styled"})
    time.sleep(1.5)
    color = sv.cmd({
        "do": "eval", "id": opened["id"],
        "js": "getComputedStyle(document.querySelector('p')).color",
    })["value"]
    t.ok("the site's CSS colors the page", color == "rgb(1, 2, 3)", color)
    sheet = sv.cmd({
        "do": "eval", "id": opened["id"],
        "js": "(document.getElementById('office-style') || {}).textContent || ''",
    })["value"]
    t.ok("the sheet is the one kept for the site", "rgb(1, 2, 3)" in sheet, sheet)
finally:
    t.done()
    sv.finish()
sys.exit(1 if t.failed else 0)
