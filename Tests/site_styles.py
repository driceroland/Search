#!/usr/bin/env python3
"""Your own style for a site: CSS of yours, worn by every page of that site.

Build first (`./build.sh`), then `python3 Tests/site_styles.py`. It uses the
split suite's harness: started hidden in a world of its own, no window shown
or brought forward, everything removed afterwards.

The style is written through the bench (`sitestyle`), as the editor writes
it, and the page is asked what it wears. Checked: nothing with the setting
off; on, the page up now changes without a reload, and a reload is styled
from its first frame; a rule of yours beats the site's own of the same
weight; CSS full of quotes, backticks, `${` and `</style>` reaches the sheet
as written and runs nothing; the setting off takes the style off the page
and keeps it; an empty style empties the sheet.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("site-styles")

HOST = "127.0.0.1"
COLOR = "p { color: rgb(1, 2, 3); }"
HOSTILE = "/* ` ${window.broken = 1} '\" </style><script>window.broken = 1</script> */ p { color: rgb(4, 5, 6); }"


def style(**f):
    return sv.cmd({"do": "sitestyle", "host": HOST, **f})


def color(id):
    return sv.ev(id, "getComputedStyle(document.querySelector('p')).color")


def sheet(id):
    return sv.ev(id, "(document.getElementById('office-style') || {}).textContent || ''")


def reload(id, page):
    sv.cmd({"do": "go", "id": id, "url": f"{sv.BASE}/{page}"})
    time.sleep(1.2)


def main():
    t = sv.T()
    try:
        sv.setup(**{"sites.styles": False})
        sv.launch()
        a = sv.page("styled")
        plain = color(a)

        s = style(css=COLOR)
        time.sleep(0.6)
        t.ok("off: the style is kept", s["written"] == COLOR, s)
        t.ok("off: but not worn", s["css"] == "" and color(a) == plain, (s, color(a)))
        reload(a, "styled")
        t.ok("off: not after a reload either", color(a) == plain and sheet(a) == "", color(a))

        style(on=True)
        time.sleep(0.6)
        t.ok("on: the page up now wears it, no reload", color(a) == "rgb(1, 2, 3)", color(a))
        reload(a, "styled")
        t.ok("on: a reload wears it from the start", color(a) == "rgb(1, 2, 3)", color(a))
        t.ok("…from one sheet", sv.ev(a, "document.querySelectorAll('#office-style').length") == 1)
        t.ok("…last in the document, so it wins over the site's own",
             sv.ev(a, "document.documentElement.lastElementChild.id") == "office-style")

        b = sv.page("another")
        t.ok("another page of the site wears it too", color(b) == "rgb(1, 2, 3)", color(b))

        style(css=HOSTILE)
        time.sleep(0.6)
        t.ok("hostile CSS: as written in the sheet", sheet(a) == HOSTILE, sheet(a))
        t.ok("…and worn", color(a) == "rgb(4, 5, 6)", color(a))
        t.ok("…and nothing ran", sv.ev(a, "typeof window.broken") == "undefined")
        reload(a, "styled")
        t.ok("hostile CSS after a reload: the same", sheet(a) == HOSTILE and color(a) == "rgb(4, 5, 6)", sheet(a))
        t.ok("…and nothing ran", sv.ev(a, "typeof window.broken") == "undefined")

        s = style(on=False)
        time.sleep(0.6)
        t.ok("off again: taken off the page", color(a) == plain and sheet(a) == "", color(a))
        t.ok("…and kept", s["written"] == HOSTILE, s)

        style(on=True)
        s = style(css="")
        time.sleep(0.6)
        t.ok("cleared: forgotten", s["written"] == "", s)
        t.ok("…and the page as the site made it", color(a) == plain and sheet(a) == "", color(a))

        # The editor's card resizes from its corner, within its least size,
        # and opens at the size it was left, after a relaunch too.
        s = style()
        first = s["size"]
        t.ok("editor: opens at 420 by 220 the first time", first == [420, 220], first)
        s = style(pull=[-120, 160])
        t.ok("editor: pulled left and down, larger", s["size"] == [540, 380], s["size"])
        sv.quit(); sv.launch()
        t.ok("editor: the size is kept", style()["size"] == [540, 380], style()["size"])
        s = style(pull=[2000, -2000])
        t.ok("editor: never under its least size", s["size"] == s["least"], s)
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
