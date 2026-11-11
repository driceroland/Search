#!/usr/bin/env python3
"""⌃Tab and the links opened behind the page, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/switcher_behind.py`. The app
starts hidden in a world of its own (see split_view.use), is driven with a
trusted ⌘-click (`tap`), the link menu (`linkmenu`) and ⌃Tab and ⌘W
(`press`), and is quit; its world is removed afterwards. Local pages only.

A link opened behind was never on screen, so the switcher never had it as a
tab left: it came after every tab left, and with ten of those it was past
the last card, missing. Now it comes right after the page (Settings › Tabs ›
⌃Tab goes to a link opened behind, on), or right after the tab left last
(off). Either way closing the page still goes back to the tab you were on,
not to the link you never looked at.
"""
import sys
import time
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("switcher-behind")

LINKS = ("document.body.innerHTML = ['l1', 'l2', 'l3'].concat(Array.from({length: 12}, function (_, i) {"
         " return 'm' + i; })).map(function (n) {"
         " return '<a id=\"' + n + '\" href=\"/behind-' + n + '\" style=\"display:block;"
         "font-size:30px;line-height:40px;padding:0 20px\">' + n + '</a>'; }).join(''); true")

CTRL_TAB = {"do": "press", "code": 48, "chars": "\t", "mods": ["ctrl"]}


def tab_for(path):
    found = [x["id"] for x in sv.sp("state")["tabs"] if urlparse(x["url"]).path == path]
    return found[0] if len(found) == 1 else None


def raise_switcher():
    """⌃Tab held: the switcher as it comes up. A press made just after the
    last gesture let go can come before the app has finished it, and is
    pressed again only when nothing came up."""
    for _ in range(2):
        sv.cmd(CTRL_TAB)
        for _ in range(10):
            time.sleep(0.2)
            sw = sv.cmd({"do": "switcher"})
            if sw["visible"] and sw["candidates"]:
                return sw
    return sw


def run(t, behind_first):
    mode = "on" if behind_first else "off (the default)"
    # Off is the default: that run writes no setting at all.
    prefs = {"tabs.closeGoesBack": True} | ({"tabs.switcherBehindFirst": True} if behind_first else {})
    sv.setup(sidebar=True, **prefs)
    sv.launch()
    # Eleven tabs gone through one by one: ten tabs left fill the grid.
    others = [sv.page(f"p{n}") for n in range(11)]
    s = sv.page("links")
    for p in others:
        sv.sp("select", id=p); time.sleep(0.25)
    last = others[-1]
    sv.sp("select", id=s); time.sleep(0.4)
    sv.ev(s, LINKS); time.sleep(0.3)

    sv.cmd({"do": "tap", "id": s, "selector": "#l1", "mods": ["cmd"]}); time.sleep(1.2)
    sv.cmd({"do": "linkmenu", "id": s, "x": 60, "y": 60, "pick": "Open Link in New Tab"}); time.sleep(1.2)
    n1, n2 = tab_for("/behind-l1"), tab_for("/behind-l2")
    st = sv.sp("state")
    t.ok(f"{mode}: ⌘-click and Open Link in New Tab each open one tab behind",
         n1 and n2 and st["activeID"] == s, (n1, n2, st["activeID"]))

    sw = raise_switcher()
    cards = sw["candidates"]
    t.ok(f"{mode}: both links are cards, with ten tabs left before them",
         n1 in cards and n2 in cards and len(cards) == 10, cards)
    want = [s, n2, n1] if behind_first else [s, last, n2, n1]
    t.ok(f"{mode}: " + ("the links right after the page, latest first" if behind_first
                        else "the tab left last, then the links, latest first"),
         cards[:len(want)] == want, (cards[:4], want))
    t.ok(f"{mode}: a quick ⌃Tab picks " + ("the latest link" if behind_first else "the tab left last"),
         sw["selected"] == want[1], (sw["selected"], want[1]))

    # Walking on one card and letting go of ⌃ takes the third card.
    sv.cmd({**CTRL_TAB, "letgo": True}); time.sleep(0.8)
    went = sv.sp("state")["activeID"]
    t.ok(f"{mode}: ⌃Tab ⌃Tab, let go: the third card", went == want[2], (went, want[2]))

    # Looked at, a link is a tab left like any other: the latest used.
    sv.sp("select", id=s); time.sleep(0.4)
    sw = raise_switcher()
    waiting = n1 if went == n2 else n2
    want = [s, went, waiting]
    t.ok(f"{mode}: once gone to, the link counts as a tab left, before the one still waiting",
         sw["candidates"][:3] == want, (sw["candidates"][:3], want))
    sv.cmd({"do": "press", "code": 53, "chars": "\x1b", "mods": ["ctrl"], "letgo": True}); time.sleep(0.6)
    t.ok(f"{mode}: Escape leaves the page in front", sv.sp("state")["activeID"] == s, sv.sp("state")["activeID"])

    # Closing the page goes back to the tab you were on, not to a link
    # waiting behind it — though that link is its neighbour in the row.
    sv.cmd({"do": "tap", "id": s, "selector": "#l3", "mods": ["cmd"]}); time.sleep(1.2)
    n3 = tab_for("/behind-l3")
    sv.cmd({"do": "press", "code": 13, "chars": "w", "mods": ["cmd"]}); time.sleep(0.8)
    now = sv.sp("state")["activeID"]
    t.ok(f"{mode}: ⌘W on the page goes back to the tab left last, not the link behind it",
         n3 and now == went, (now, went, n3))

    # A dozen links from one page, as on Pinterest: the newest keep their
    # cards and the oldest go out.
    page = sv.page("board")
    sv.sp("select", id=page); time.sleep(0.4)
    sv.ev(page, LINKS); time.sleep(0.3)
    for i in range(12):
        sv.cmd({"do": "tap", "id": page, "selector": f"#m{i}", "mods": ["cmd"]}); time.sleep(0.5)
    time.sleep(0.8)
    m = [tab_for(f"/behind-m{i}") for i in range(12)]
    sw = raise_switcher()
    cards = sw["candidates"]
    newest = m[::-1]
    want = [page] + newest[:9] if behind_first else [page, now] + newest[:8]
    t.ok(f"{mode}: twelve links: the newest keep their cards, the oldest go out",
         all(m) and cards == want, ([c for c in cards], want))
    sv.cmd({"do": "press", "code": 53, "chars": "\x1b", "mods": ["ctrl"], "letgo": True}); time.sleep(0.6)


def main():
    t = sv.T()
    try:
        for behind_first in (True, False):
            run(t, behind_first)
            sv.quit()
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
