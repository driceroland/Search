#!/usr/bin/env python3
"""Settings › Spaces & Pins › Links from pinned tabs open in a new tab (idea 1039).

Build first (`./build.sh`), then `python3 Tests/pin_links_tabs.py`. Uses the
split suite's harness: started hidden, no window made or shown, everything
removed afterwards. 127.0.0.1 and localhost stand for two sites.

Off (as it ships), a link within the pin's site still loads in the pin. On,
a clicked link opens a loose tab in front, from a pin in a folder or not,
and the pin stays; a #fragment jump, a sign-in page of the site, a form
and a page's own script navigation stay in the pin.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("pin-links-tabs")
t = sv.T()
OTHER = sv.BASE.replace("127.0.0.1", "localhost")


def pin(id, **f): return sv.cmd({"do": "pin", "id": id, **f})
def pf(**f): return sv.cmd({"do": "pinfolder", **f})


def tap(id, href):
    """A link as a hand clicks it (bench `tap`), not element .click()."""
    sv.ev(id, f"document.getElementById('go')?.remove(); var a = document.createElement('a'); a.id = 'go'; a.href = '{href}'; a.textContent = 'go'; a.style = 'position:fixed;left:0;top:0;width:200px;height:120px;display:block;font-size:40px'; document.body.appendChild(a); true")
    sv.cmd({"do": "tap", "id": id, "selector": "#go"})
    time.sleep(1.5)


def loose(st):
    """The loose tabs with a page: closing the last one may leave a new
    blank tab (Leave a new tab when the last tab closes)."""
    return [x for x in st["tabs"] if x["id"] not in st["pins"] and x["url"]]


def tidy(keep):
    st = sv.sp("state")
    for x in loose(st):
        sv.sp("close", id=x["id"])
    sv.sp("select", id=keep); time.sleep(0.5)


try:
    sv.setup(sidebar=True); sv.launch()
    pf(action="on")
    a = sv.page("home"); pf(action="pin", id=a); pf(action="new", name="Subs", id=a); sv.sp("select", id=a); time.sleep(0.5)
    t.ok("the pin is in a folder", ["home", "Subs"] in [x[1:] for x in pf(action="state")["order"]] or any(x[2] == "Subs" for x in pf(action="state")["order"]), pf(action="state")["order"])
    t.ok("off by default", sv.cmd({"do": "settings", "find": "pinned"})["values"].get("pins.linksNewTab") is False)

    # Off: as before, a link within the site goes in the pin.
    tap(a, f"{sv.BASE}/inner-off")
    st = sv.sp("state")
    t.ok("off: a link within the site loads in the pin", sv.url(st, a).endswith("/inner-off"), sv.url(st, a))
    t.ok("off: no tab opened", not any(x["url"].endswith("/inner-off") for x in loose(st)), [x["url"] for x in loose(st)])
    sv.sp("close", id=a); time.sleep(0.8)  # ⌘W: back home
    sv.sp("select", id=a); time.sleep(1.0)

    sv.cmd({"do": "settings", "set": "pins.linksNewTab", "value": True}); time.sleep(0.5)
    tap(a, f"{sv.BASE}/inner-on")
    st = sv.sp("state")
    opened = [x for x in loose(st) if x["url"].endswith("/inner-on")]
    t.ok("on: a link within the site opens a loose tab", len(opened) == 1, [x["url"] for x in st["tabs"]])
    t.ok("…in front", opened and st.get("activeID") == opened[0]["id"], (st.get("activeID"), opened))
    t.ok("…and the pin stays on its page", sv.url(st, a).endswith("/home"), sv.url(st, a))
    tidy(a)

    tap(a, f"{OTHER}/elsewhere")
    st = sv.sp("state")
    t.ok("on: a link to another site opens a loose tab, not a peek",
         any(x["url"].endswith("/elsewhere") for x in loose(st)) and sv.cmd({"do": "probe"})["peek"] == "",
         ([x["url"] for x in st["tabs"]], sv.cmd({"do": "probe"})["peek"]))
    tidy(a)

    tap(a, "#part")
    st = sv.sp("state")
    t.ok("on: a #fragment jump stays in the pin", sv.url(st, a).endswith("/home#part") and not loose(st), (sv.url(st, a), [x["url"] for x in loose(st)]))

    tap(a, f"{sv.BASE}/login")
    st = sv.sp("state")
    t.ok("on: the site's sign-in page stays in the pin", sv.url(st, a).endswith("/login") and not loose(st), (sv.url(st, a), [x["url"] for x in loose(st)]))
    sv.sp("close", id=a); time.sleep(0.8); sv.sp("select", id=a); time.sleep(1.0)

    sv.ev(a, f"setTimeout(function () {{ location.href = '{sv.BASE}/by-script' }}, 100); true"); time.sleep(1.5)
    st = sv.sp("state")
    t.ok("on: the page's own script navigation stays in the pin", sv.url(st, a).endswith("/by-script") and not loose(st), (sv.url(st, a), [x["url"] for x in loose(st)]))
    sv.sp("close", id=a); time.sleep(0.8); sv.sp("select", id=a); time.sleep(1.0)

    sv.ev(a, f"var f = document.createElement('form'); f.action = '{sv.BASE}/posted'; f.method = 'get'; document.body.appendChild(f); f.submit(); true"); time.sleep(1.5)
    st = sv.sp("state")
    t.ok("on: a form stays in the pin", "/posted" in sv.url(st, a) and not loose(st), (sv.url(st, a), [x["url"] for x in loose(st)]))
    sv.sp("close", id=a); time.sleep(0.8)

    # A loose pin, not in a folder, as a square.
    b = sv.page("square"); pin(b); sv.sp("select", id=b); time.sleep(0.5)
    tap(b, f"{sv.BASE}/from-square")
    st = sv.sp("state")
    t.ok("on: a pin outside any folder too", any(x["url"].endswith("/from-square") for x in loose(st)) and sv.url(st, b).endswith("/square"),
         ([x["url"] for x in st["tabs"]], sv.url(st, b)))
    tidy(b)

    # A loose tab is untouched.
    c = sv.page("plain"); sv.sp("select", id=c); time.sleep(0.5)
    before = len(sv.sp("state")["tabs"])
    tap(c, f"{sv.BASE}/plain-next")
    st = sv.sp("state")
    t.ok("a link in a loose tab still loads in it", sv.url(st, c).endswith("/plain-next") and len(st["tabs"]) == before, (sv.url(st, c), len(st["tabs"]), before))
finally:
    sv.finish()
t.done()
sys.exit(1 if t.failed else 0)
