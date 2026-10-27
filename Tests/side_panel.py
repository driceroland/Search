#!/usr/bin/env python3
"""An extension's side panel (chrome.sidePanel, idea 261), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/side_panel.py [PICTURES]`.
It runs in a world of its own with split_view.py's harness: started hidden,
everything removed afterwards. The extensions are folders made here: one
with a panel, one whose panel page is missing.

Where the panel sits: with the page as a card, a card of its own on the side
away from the column, after the same gap; edge to edge (the switch off, the
window in full screen as the chrome sees it, the tabs across the top) at the
window's edge with a hairline before it; in Split View the pair shares what
is left. What the panel may do (Security's checks): no window without a
gesture, window.open only to what a tab may open, its top frame kept to the
extension's own pages, a site it goes to opening in a tab only after a real
click or key, one click one tab. A panel that can't load opens as a tab, as
before there was a panel. Given a folder, a picture of each state goes there,
light and dark; nothing is shown on any screen to take them.
"""
import json
import os
import shutil
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("side-panel")
GAP = 8
WIDTH = 380
# The panel's own line above its page: the extension's name and a close button.
HEAD = 43
PICTURES = sys.argv[1] if len(sys.argv) > 1 else None
work = Path(tempfile.mkdtemp(prefix="search-sidepanel-"))


def make(name, panel, pages=()):
    folder = work / name.replace(" ", "")
    folder.mkdir()
    (folder / "manifest.json").write_text(json.dumps({
        "manifest_version": 3, "name": name, "version": "1.0",
        "permissions": ["sidePanel", "tabs"],
        "action": {"default_title": name},
        "side_panel": {"default_path": panel},
    }))
    for file, body in pages:
        (folder / file).write_text(body)
    return str(folder)


PANEL = f"""<!doctype html><title>The panel</title>
<p>Panel</p>
<a id=out href="{sv.BASE}/out">out</a>
<a id=far href="{sv.BASE}/far" target=_blank>far</a>
"""


def make_later():
    """An extension whose panel is off on every tab, as ChatGPT's is, until
    its button's onClicked turns it on for the tab and opens it."""
    folder = work / "PanelLater"
    folder.mkdir(exist_ok=True)
    (folder / "manifest.json").write_text(json.dumps({
        "manifest_version": 3, "name": "Panel Later", "version": "1.0",
        "permissions": ["sidePanel", "tabs"],
        "action": {"default_title": "Panel Later"},
        "side_panel": {"default_path": "waiting.html"},
        "background": {"service_worker": "worker.js"},
    }))
    (folder / "waiting.html").write_text("<!doctype html><title>waiting</title>")
    (folder / "work.html").write_text("<!doctype html><title>work</title>")
    (folder / "worker.js").write_text("""
chrome.sidePanel.setOptions({ enabled: false });
chrome.sidePanel.setPanelBehavior({ openPanelOnActionClick: true });
chrome.tabs.query({}).then((tabs) => tabs.forEach((tab) =>
  chrome.sidePanel.setOptions({ tabId: tab.id, enabled: false, path: "work.html" })));
chrome.action.onClicked.addListener((tab) => {
  chrome.sidePanel.setOptions({ tabId: tab.id, enabled: true, path: "work.html" });
  chrome.sidePanel.open({ tabId: tab.id });
});
""")
    return str(folder)


def installed(): return sv.cmd({"do": "extensions"})["extensions"]


def add(path, name):
    sv.cmd({"do": "ext-folder", "path": path, "yes": True})
    for _ in range(50):
        found = [x for x in installed() if x["name"] == name and x["loaded"]]
        if found: return found[0]
        time.sleep(0.2)
    raise RuntimeError(f"{name} didn't load")


def panel(action="state", **f): return sv.cmd({"do": "sidepanel", "action": action, **f})


def peval(js): return panel("eval", js=js).get("value")


def ui(**f):
    sv.cmd({"do": "ui", **f}); time.sleep(0.9)


def window():
    p = sv.cmd({"do": "probe"})
    w = next(w for w in p["windows"] if w["kind"] == "AppKitWindow")
    return p, w["frame"][2], w["frame"][3]


def pages():
    """Every page on screen but the panel's: x, y, right, bottom."""
    return sorted((f[0], f[1], f[0] + f[2], f[1] + f[3]) for f in panel()["pages"] if f)


def box():
    """The panel, from the window's top-left corner: x, y, right, bottom,
    its own line above the page included."""
    f = panel()["frame"]
    return (f[0], f[1] - HEAD, f[0] + f[2], f[1] + f[3]) if f else None


def urls(): return [x["url"] for x in sv.sp("state")["tabs"]]


def opened(path): return sum(1 for u in urls() if u.rstrip("/").endswith(path))


def wait(cond, within=6):
    until = time.time() + within
    while time.time() < until:
        if cond(): return True
        time.sleep(0.2)
    return cond()


def picture(name):
    if not PICTURES: return
    for look in ("light", "dark"):
        ui(look=look)
        sv.cmd({"do": "picture", "path": f"{PICTURES}/panel2-{name}-{look}.png", "page": False})
    ui(look="system")


def press(ext):
    sv.cmd({"do": "ext-press", "id": ext["id"]}); time.sleep(1.2)


def up(): return panel()["shown"]


def main():
    t = sv.T()
    if PICTURES: os.makedirs(PICTURES, exist_ok=True)
    good = make("Panel One", "panel.html", [("panel.html", PANEL), ("page.html", "<!doctype html><title>own</title>")])
    broken = make("Panel Gone", "missing.html", [("page.html", "<!doctype html><title>own</title>")])
    try:
        # The window's layouts, one page and a pair.
        for split in (False, True):
            kind = "a pair" if split else "one page"
            tag = "pair-" if split else ""
            sv.setup(sidebar=True, splitView=split); sv.launch()
            a = sv.page("a")
            if split:
                b = sv.page("b")
                sv.sp("pair", id=b, **{"with": a}, side="right"); time.sleep(0.8)
                sv.sp("focus", id=a); time.sleep(0.4)
            ext = add(good, "Panel One")
            # The button opens the panel: the extension asks for that from a
            # page of its own, as its worker would at launch.
            page = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "page.html"})["id"]
            time.sleep(1.0)
            sv.cmd({"do": "eval", "id": page, "js": "chrome.sidePanel.setPanelBehavior({openPanelOnActionClick: true}); 1"})
            time.sleep(0.6)
            sv.sp("select", id=a); time.sleep(0.5)
            before = pages()
            p, w, h = window()
            side = p["sideWidth"]

            press(ext)
            st = panel()
            t.ok(f"{kind}: the button opens the panel, not a tab", st["shown"] and st["content"]["kind"] == "page"
                 and st["content"]["url"].endswith("/panel.html") and opened("/panel.html") == 0, (st, urls()))
            wait(lambda: panel()["title"] == "The panel")
            t.ok(f"{kind}: its page is the extension's", panel()["title"] == "The panel" and panel()["page"].startswith(ext["base"].rstrip("/")), panel())
            t.ok(f"{kind}: no window without a gesture", st["opensWindows"] is False, st)
            # Claude's panel asks where it is before anything else: no tab
            # (undefined, as Chrome answers, not null) and listed as a
            # SIDE_PANEL context, or it says "Claude isn't available on this page".
            peval("window.__where = null; (async () => { const t = await chrome.tabs.getCurrent();"
                  " const c = await chrome.runtime.getContexts({documentUrls: [location.href]});"
                  " window.__where = JSON.stringify({tab: t === undefined ? 'undefined' : t, types: c.map(x => x.contextType)}) })(); 1")
            wait(lambda: peval("window.__where"), within=3)
            where = json.loads(peval("window.__where") or "{}")
            t.ok(f"{kind}: in the panel, tabs.getCurrent() is undefined, as in Chrome", where.get("tab") == "undefined", where)
            t.ok(f"{kind}: and runtime.getContexts lists it as a SIDE_PANEL", where.get("types") == ["SIDE_PANEL"], where)

            # With the page as a card: a card of its own on the right.
            r = box()
            t.ok(f"{kind}: card: on the far side, the card's gap round it", r == (w - GAP - WIDTH, GAP, w - GAP, h - GAP), (r, w, h))
            # As far from the panel as it was from the window's edge (a pair
            # keeps its own inset there too).
            far = w - max(x[2] for x in before)
            ends = max(x[2] for x in pages())
            t.ok(f"{kind}: card: the page ends a gap before it", ends == r[0] - far and far >= GAP, (ends, far, r))
            t.ok(f"{kind}: card: the page keeps its top, bottom and column side",
                 min(x[0] for x in pages()) == min(x[0] for x in before)
                 and [(x[1], x[3]) for x in pages()] == [(x[1], x[3]) for x in before], (before, pages()))
            if split:
                both = pages()
                t.ok("a pair: the two share what's left", len(both) == 2 and both[0][2] < both[1][0]
                     and abs((both[0][2] - both[0][0]) - (both[1][2] - both[1][0])) <= 1, both)
            picture(f"{tag}card")

            # The column on the right: the panel on the left.
            ui(side="right")
            r = box()
            t.ok(f"{kind}: column on the right, the panel on the left", r == (GAP, GAP, GAP + WIDTH, h - GAP), r)
            t.ok(f"{kind}: column on the right, the page a gap after it", min(x[0] for x in pages()) == r[2] + GAP, pages())
            picture(f"{tag}card-left")
            ui(side="left")

            # Edge to edge: the switch off.
            ui(cards=False)
            r = box()
            t.ok(f"{kind}: edge to edge, at the window's edge", r == (w - WIDTH, 0, w, h), (r, w, h))
            t.ok(f"{kind}: edge to edge, the page up to its hairline", max(x[2] for x in pages()) == w - WIDTH - 1, pages())
            picture(f"{tag}edge")
            ui(cards=True)

            # The window in full screen, as the chrome sees it: edge to edge.
            ui(fullscreen=True)
            r = box()
            t.ok(f"{kind}: full screen, edge to edge", r == (w - WIDTH, 0, w, h) and max(x[2] for x in pages()) == w - WIDTH - 1, (r, pages()))
            ui(fullscreen=False)
            t.ok(f"{kind}: out of full screen, a card again", box() == (w - GAP - WIDTH, GAP, w - GAP, h - GAP), box())

            # The tabs across the top: at the right edge, under the strip.
            ui(sidebar=False)
            r = box()
            top = min(x[1] for x in pages())
            t.ok(f"{kind}: tabs across the top, at the right edge under the strip",
                 r == (w - WIDTH, top, w, h) and top > 0, (r, top))
            t.ok(f"{kind}: tabs across the top, the page up to its hairline", max(x[2] for x in pages()) == w - WIDTH - 1, pages())
            picture(f"{tag}across")
            ui(sidebar=True)

            # The column folded away: still on the far side.
            ui(folded=True)
            r = box()
            t.ok(f"{kind}: folded, the panel stays", r == (w - GAP - WIDTH, GAP, w - GAP, h - GAP), r)
            ui(folded=False)

            # The button again: it goes, and the page has its room back.
            press(ext)
            t.ok(f"{kind}: the button again closes it", not up() and box() is None, panel())
            t.ok(f"{kind}: closed, the page as before", pages() == before, (before, pages()))
            if split:
                sv.quit(); continue

            # chrome.sidePanel as Chrome answers it.
            sv.cmd({"do": "eval", "id": page, "js": "chrome.sidePanel.open({windowId: 1}).then(() => window.__o = 'ok', e => window.__o = String(e)); 1"})
            time.sleep(1.2)
            t.ok("sidePanel.open opens it", up(), panel())
            sv.cmd({"do": "eval", "id": page, "js": "chrome.sidePanel.close({windowId: 1}).then(() => window.__c = 'ok', e => window.__c = String(e)); 1"})
            time.sleep(0.8)
            t.ok("sidePanel.close closes it", not up(), panel())
            sv.cmd({"do": "eval", "id": page, "js": "chrome.sidePanel.getOptions({}).then(o => window.__g = JSON.stringify(o)); 1"})
            time.sleep(0.6)
            g = json.loads(sv.cmd({"do": "eval", "id": page, "js": "window.__g"}).get("value") or "{}")
            t.ok("getOptions: enabled, its default page", g.get("enabled") is True and g.get("path") == "panel.html", g)

            # A panel for one tab goes and comes with it.
            c = sv.page("c")
            sv.sp("select", id=a); time.sleep(0.5)
            sv.cmd({"do": "eval", "id": page, "js": """chrome.tabs.query({active: true, lastFocusedWindow: true}).then(([tab]) =>
                chrome.sidePanel.setOptions({tabId: tab.id, path: 'panel.html?for=a'}).then(() =>
                chrome.sidePanel.open({tabId: tab.id}))).then(() => window.__t = 'ok', e => window.__t = String(e)); 1"""})
            time.sleep(1.5)
            st = panel()
            t.ok("per tab: open for this tab", st["shown"] and st["content"]["url"].endswith("panel.html?for=a") and st["content"]["tab"] != "", st)
            sv.sp("select", id=c); time.sleep(0.6)
            t.ok("per tab: another tab, it goes", not up(), panel())
            sv.sp("select", id=a); time.sleep(1.0)
            t.ok("per tab: back on its tab, it's back", up() and panel()["content"]["url"].endswith("panel.html?for=a"), panel())
            panel("close"); time.sleep(0.4)

            # setOptions enabled: false while it's up: it goes.
            press(ext)
            sv.cmd({"do": "eval", "id": page, "js": "chrome.sidePanel.setOptions({enabled: false}); 1"}); time.sleep(0.8)
            t.ok("enabled: false closes it", not up(), panel())
            press(ext)
            t.ok("enabled: false, the button opens nothing", not up() and opened("/panel.html") == 0, (panel(), urls()))
            sv.cmd({"do": "eval", "id": page, "js": "chrome.sidePanel.setOptions({enabled: true}); 1"}); time.sleep(0.6)

            # Security's checks, on the panel's own page.
            press(ext)
            wait(lambda: panel()["title"] == "The panel")
            n = len(urls())
            peval(f"window.open('{sv.BASE}/w1'); 1"); time.sleep(1.0)
            t.ok("security: window.open goes to a tab", opened("/w1") == 1 and up(), urls())
            peval("window.open('file:///etc/hosts'); 1"); time.sleep(0.8)
            t.ok("security: window.open to a file opens nothing", not any(u.startswith("file:") for u in urls()), urls())
            peval("window.open('javascript:alert(1)'); 1"); time.sleep(0.8)
            t.ok("security: window.open to javascript: opens nothing", len(urls()) == n + 1, urls())
            peval(f"location.href = '{sv.BASE}/away'; 1"); time.sleep(1.0)
            st = panel()
            t.ok("security: the panel stays on the extension's own pages", st["page"].startswith(ext["base"].rstrip("/")) and st["title"] == "The panel", st)
            t.ok("security: a site without a hand opens no tab", opened("/away") == 0, urls())
            peval(f"let i = 0; const go = setInterval(() => {{ location.href = '{sv.BASE}/loop' + (i++); if (i > 8) clearInterval(go) }}, 60); 1")
            time.sleep(1.6)
            t.ok("security: a page sending itself away over and over opens no tab", not any("/loop" in u for u in urls()), urls())
            panel("touch")
            peval("document.getElementById('out').click(); document.getElementById('out').click(); 1"); time.sleep(1.2)
            t.ok("security: a link after a real click opens one tab, once", opened("/out") == 1, urls())
            t.ok("security: the panel is still the extension's", panel()["page"].startswith(ext["base"].rstrip("/")), panel())
            time.sleep(1.2)
            peval("document.getElementById('out').click(); 1"); time.sleep(1.0)
            t.ok("security: the same click, a second later, opens nothing more", opened("/out") == 1, urls())

            # The extension removed: its panel with it.
            sv.cmd({"do": "ext-remove", "id": ext["id"]}); time.sleep(1.0)
            t.ok("removed: its panel goes", not up(), panel())

            # A panel whose page can't load opens as a tab, as before.
            gone = add(broken, "Panel Gone")
            page2 = sv.cmd({"do": "ext-page", "id": gone["id"], "path": "page.html"})["id"]
            time.sleep(1.0)
            sv.cmd({"do": "eval", "id": page2, "js": "chrome.sidePanel.setPanelBehavior({openPanelOnActionClick: true}); 1"}); time.sleep(0.6)
            press(gone); time.sleep(1.5)
            t.ok("fallback: a panel that can't load opens as a tab", not up() and opened("/missing.html") == 1, (panel(), urls()))

            # ChatGPT's way: the button asked to open the panel, but the panel
            # is off everywhere until the extension's onClicked turns it on
            # for the tab pressed on. As in Chrome, a press over a tab with no
            # panel turned on is the extension's, and the panel then opens.
            sv.cmd({"do": "ext-remove", "id": gone["id"]}); time.sleep(0.6)
            sv.sp("select", id=a); time.sleep(0.5)
            later = add(make_later(), "Panel Later")
            time.sleep(2.0)
            press(later); time.sleep(1.0)
            st = panel()
            t.ok("off until clicked: the press reaches the extension, which opens its panel",
                 st["shown"] and st["content"]["kind"] == "page" and st["content"]["url"].endswith("/work.html")
                 and st["content"]["tab"] != "" and opened("/work.html") == 0, (st, urls()))
            press(later)
            t.ok("off until clicked: turned on for this tab, the button again closes it", not up(), panel())
            press(later)
            t.ok("off until clicked: and opens it again", up() and panel()["content"]["url"].endswith("/work.html"), panel())
            panel("close"); time.sleep(0.4)
            sv.cmd({"do": "ext-remove", "id": later["id"]}); time.sleep(0.6)

            # The width, as left: kept within 300–640.
            sv.quit()
            sv.setup(sidebar=True)
            os.system(f"defaults write {sv.SUITE} sidepanel.width -float 9999")
            sv.launch()
            sv.page("a")
            ext = add(good, "Panel One")
            page = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "page.html"})["id"]; time.sleep(1.0)
            sv.cmd({"do": "eval", "id": page, "js": "chrome.sidePanel.open({windowId: 1}); 1"}); time.sleep(1.2)
            st = panel()
            p, w, h = window()
            r = box()
            t.ok("width: too wide a setting is kept to 640", st["width"] == 640, st["width"])
            t.ok("width: drawn narrower in a window too narrow for it", r is not None and r[2] - r[0] <= max(240, w - p["sideWidth"] - 2 * GAP - 320), (r, w))
            sv.quit()
    finally:
        t.done(); sv.finish(); shutil.rmtree(work, ignore_errors=True)
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
