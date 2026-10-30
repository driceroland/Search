#!/usr/bin/env python3
"""A link's right-click menu, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/link_menu.py`. The right
button is pressed on a link through the page's own view, and the item is
chosen as the menu comes up (the bench's linkmenu), so WebKit makes the tab
as it does for a hand; no window is made or shown.
"""
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# Its own world, apart from the split suite's in this checkout (see use()).
sv.use("link-menu")

LINK = ("document.body.innerHTML = '<a href=\"{}\" style=\"display:block;"
        "font-size:60px;line-height:120px;padding:0 20px\">a link</a>'; true")

# A link whose whole face is a picture, as a grid of posts has: the picture
# drawn here, so it is a real one, wrapped as such a grid wraps it.
PICTURE = """(function () {{
  var c = document.createElement('canvas'); c.width = 200; c.height = 200;
  c.getContext('2d').fillRect(0, 0, 200, 200);
  document.body.innerHTML = '<a href="{}"><div><picture><img style="display:block;width:200px;height:200px" src="'
    + c.toDataURL() + '"></picture></div></a>';
  return true;
}})()"""


def menu(tab, pick):
    sv.ev(tab, LINK.format(f"{sv.BASE}/{pick[1]}")); time.sleep(0.3)
    return sv.cmd({"do": "linkmenu", "id": tab, "x": 60, "y": 60, "pick": pick[0]})


def spot(tab, selector):
    """The first link the selector finds on a site's page, scrolled into the
    middle of the view: where to press, in the page's own points, and where
    it goes."""
    return sv.ev(tab, f"""(function () {{
      var a = document.querySelector({json.dumps(selector)}); if (!a) return null;
      a.scrollIntoView({{block: 'center'}}); var r = a.getBoundingClientRect();
      return [r.left + Math.min(r.width / 2, 40), r.top + r.height / 2, a.href]; }})()""")


def site(t, name, url, selector):
    """Open Link in Split View on a link of a site as it is, skipped when the
    site doesn't load."""
    tab = sv.sp("open", url=url)["resultID"]
    sv.sp("select", id=tab); sv.cmd({"do": "wait", "id": tab, "seconds": 25})
    found = None
    for _ in range(20):
        found = spot(tab, selector)
        if found: break
        time.sleep(1)
    if not found:
        print(f"  skip  {name}: no link found (didn't load?)"); return
    time.sleep(0.8)
    # A page can keep the right button for itself: no menu comes up, in
    # Search as in Safari, and there is nothing to choose.
    sv.ev(tab, """(function () { window.__menuKept = false;
      window.addEventListener('contextmenu', function (e) {
        setTimeout(function () { window.__menuKept = e.defaultPrevented; }, 0); }, true); return 1 })()""")
    before = {x["id"] for x in sv.sp("state")["tabs"]}
    sv.cmd({"do": "linkmenu", "id": tab, "x": found[0], "y": found[1], "pick": "Open Link in Split View"}); time.sleep(2)
    if sv.ev(tab, "window.__menuKept") is True:
        print(f"  skip  {name}: the page keeps its right-click menu for itself"); return
    st = sv.sp("state")
    new = [x["id"] for x in st["tabs"] if x["id"] not in before]
    t.ok(f"{name}: one new tab for {found[2]}", len(new) == 1, new)
    t.ok(f"{name}: in a pair with the page it came from",
         bool(new) and any(s["tabs"] == [tab, new[0]] for s in st["splits"]), st["splits"])
    t.ok(f"{name}: the link's page has the keys", bool(new) and st["activeID"] == new[0], st["activeID"])


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
        # The picture's own menu stands in for WebKit's only where there is
        # no link: on a link's picture, the link's items are there too.
        sv.sp("select", id=a); time.sleep(0.4)
        sv.ev(a, PICTURE.format(f"{sv.BASE}/pictured")); time.sleep(0.3)
        r = sv.cmd({"do": "linkmenu", "id": a, "x": 60, "y": 60, "pick": "Open Link in New Tab"})
        t.ok("a link's picture: Open Link in New Tab opens the link",
             any(u.endswith("/pictured") for u in r["urls"]), r["urls"])
    finally:
        sv.finish()
    try:
        # With Split View on, the menu has Open Link in Split View.
        sv.setup(splitView=True); sv.launch()
        a = sv.page("a"); b = sv.page("b")
        sv.sp("select", id=a); time.sleep(0.4)
        menu(a, ("Open Link in Split View", "beside")); time.sleep(0.5)
        st = sv.sp("state")
        new = [x["id"] for x in st["tabs"] if x["url"].endswith("/beside")]
        t.ok("Open Link in Split View: a new tab for the link", len(new) == 1, st["tabs"])
        t.ok("…in a pair with the page it came from, on its right",
             bool(new) and any(s["tabs"] == [a, new[0]] for s in st["splits"]), st["splits"])
        t.ok("…and the link's page has the keys", bool(new) and st["activeID"] == new[0], st["activeID"])
        # The ⌥ item still follows Open Link in New Tab, as an alternate must.
        sv.sp("select", id=b); time.sleep(0.4)
        r = menu(b, ("Open Link in New Tab and Go to It", "front"))
        front = [x for x, u in zip(r["tabs"], r["urls"]) if u.endswith("/front")]
        t.ok("Split View on: Open Link in New Tab and Go to It still goes to it",
             len(front) == 1 and r["active"] == front[0], r)
        # From a page already in a pair: the link takes the other page's
        # place, and that page stays open, a tab of its own.
        sv.sp("select", id=a); time.sleep(0.4)
        menu(a, ("Open Link in Split View", "again")); time.sleep(0.5)
        st = sv.sp("state")
        again = [x["id"] for x in st["tabs"] if x["url"].endswith("/again")]
        t.ok("from a pair: the link takes the other page's place",
             bool(again) and any(s["tabs"] == [a, again[0]] for s in st["splits"]), st["splits"])
        t.ok("from a pair: the page it replaced stays open, in no pair",
             bool(new) and new[0] in [x["id"] for x in st["tabs"]]
             and not any(new[0] in s["tabs"] for s in st["splits"]), (st["tabs"], st["splits"]))
        # From a pin: the pin keeps its place, its page goes into the pair.
        p = sv.page("pinned"); sv.cmd({"do": "pin", "id": p}); sv.sp("select", id=p); time.sleep(0.4)
        menu(p, ("Open Link in Split View", "frompin")); time.sleep(0.8)
        st = sv.sp("state")
        frompin = [x["id"] for x in st["tabs"] if x["url"].endswith("/frompin")]
        pair = next((s for s in st["splits"] if frompin and frompin[0] in s["tabs"]), None)
        t.ok("from a pin: the link in a pair, beside a page that isn't the pin",
             pair is not None and p not in pair["tabs"], st["splits"])
        # Sites as they are.
        site(t, "Wikipedia", "https://en.wikipedia.org/wiki/WebKit", '#mw-content-text p a[href^="/wiki/"], #mw-content-text p a[href^="https://en.wikipedia.org/wiki/"]')
        # A card's channel name: its picture keeps the right button for
        # Twitch's own menu.
        site(t, "Twitch", "https://www.twitch.tv/directory/all", 'a[data-a-target="preview-card-channel-link"]')
        # Off, the item isn't there: picking it chooses nothing.
        sv.sp("enabled", on=False); time.sleep(0.3)
        r = menu(b, ("Open Link in Split View", "nowhere"))
        t.ok("Split View off: no Open Link in Split View",
             not any(u.endswith("/nowhere") for u in r["urls"]), r["urls"])
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
