#!/usr/bin/env python3
"""A link's right-click menu, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/link_menu.py`. The right
button is pressed on a link through the page's own view, and the item is
chosen as the menu comes up (the bench's linkmenu), so WebKit makes the tab
as it does for a hand; no window is made or shown.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

LINK = ("document.body.innerHTML = '<a href=\"{}\" style=\"display:block;"
        "font-size:60px;line-height:120px;padding:0 20px\">a link</a>'; true")


def menu(tab, pick):
    sv.ev(tab, LINK.format(f"{sv.BASE}/{pick[1]}")); time.sleep(0.3)
    return sv.cmd({"do": "linkmenu", "id": tab, "x": 60, "y": 60, "pick": pick[0]})


def main():
    t = sv.T()
    try:
        sv.setup(); sv.launch()
        a = sv.page("a"); b = sv.page("b")
        sv.sp("select", id=a); time.sleep(0.4)
        r = menu(a, ("Open Link in New Tab", "behind"))
        new = [x for x, u in zip(r["tabs"], r["urls"]) if u.endswith("/behind")]
        t.ok("Open Link in New Tab: a new tab for the link", len(new) == 1, r)
        t.ok("it stays behind: the tab you were on is still in front", r["active"] == a, r)
        t.ok("it goes just after the tab it came from, as a ⌘-click's does",
             bool(new) and r["tabs"].index(new[0]) == r["tabs"].index(a) + 1, r["tabs"])
        r = menu(a, ("Open Link in New Tab and Go to It", "front"))
        new = [x for x, u in zip(r["tabs"], r["urls"]) if u.endswith("/front")]
        t.ok("with ⌥, Open Link in New Tab and Go to It: the new tab is in front",
             len(new) == 1 and r["active"] == new[0], r)
        t.ok("b is untouched", b in r["tabs"], r["tabs"])
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
