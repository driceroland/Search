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


def open_styled():
    opened = sv.cmd({"do": "open", "url": f"{sv.BASE}/styled"})
    time.sleep(1.5)
    return opened["id"]


def page_color(tab):
    return sv.cmd({
        "do": "eval", "id": tab,
        "js": "getComputedStyle(document.querySelector('p')).color",
    })["value"]


def sheet(tab):
    return sv.cmd({
        "do": "eval", "id": tab,
        "js": "(document.getElementById('office-style') || {}).textContent || ''",
    })["value"]


try:
    # The first version of the file stored the CSS as a string.
    sv.setup(**{"styles.sites": True})
    os.makedirs(sv.SUPPORT, exist_ok=True)
    with open(f"{sv.SUPPORT}/styles.json", "w") as fh:
        json.dump({"127.0.0.1": "p { color: rgb(1, 2, 3) }"}, fh)
    sv.launch()
    tab = open_styled()
    color = page_color(tab)
    t.ok("a CSS string from the first version still colors the page", color == "rgb(1, 2, 3)", color)
    text = sheet(tab)
    t.ok("the sheet is the one kept for the site", "rgb(1, 2, 3)" in text, text)

    # A look: its color wins, its CSS is kept, and its JavaScript runs once.
    sv.setup(**{"styles.sites": True})
    os.makedirs(sv.SUPPORT, exist_ok=True)
    with open(f"{sv.SUPPORT}/styles.json", "w") as fh:
        json.dump({
            "127.0.0.1": {
                "on": True,
                "text": "#010203",
                "css": "p { color: rgb(4, 5, 6) }",
                "script": "document.documentElement.dataset.ran = 'yes'",
            }
        }, fh)
    sv.launch()
    tab = open_styled()
    color = page_color(tab)
    t.ok("the site's color wins over a rule without importance", color == "rgb(1, 2, 3)", color)
    text = sheet(tab)
    t.ok("the sheet keeps the CSS written for the site", "rgb(4, 5, 6)" in text, text)
    ran = sv.cmd({
        "do": "eval", "id": tab,
        "js": "document.documentElement.dataset.ran || ''",
    })["value"]
    t.ok("the site's JavaScript runs as the page loads", ran == "yes", ran)
finally:
    t.done()
    sv.finish()
sys.exit(1 if t.failed else 0)
