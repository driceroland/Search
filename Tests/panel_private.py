#!/usr/bin/env python3
"""An extension's side panel beside a private tab (issue 662), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/panel_private.py [PICTURES]`.
It runs in a world of its own with split_view.py's harness: started hidden,
everything removed afterwards. The extension is a folder made here, with a
panel of its own.

What it checks: a window's panel is held back while a private tab is in
front, the page taking the room it had; the switch in Settings > Extensions
(ext-private) lets it through there and shuts it out again; the panel's own
page is kept while it waits, so it comes back as it was rather than loading
again; and sidePanel.open, asked for over a private tab by an extension not
let in, opens nothing at all, a tab included. Given a folder, a picture of
the panel beside an ordinary tab and of the page with it held back goes
there, light and dark; nothing is shown on any screen to take them.
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

sv.use("panel-private")
PICTURES = sys.argv[1] if len(sys.argv) > 1 else None
work = Path(tempfile.mkdtemp(prefix="search-panelprivate-"))

PANEL = """<!doctype html><title>The panel</title>
<p>Panel</p>
"""


def make():
    folder = work / "PanelPrivate"
    folder.mkdir()
    (folder / "manifest.json").write_text(json.dumps({
        "manifest_version": 3, "name": "Panel Private", "version": "1.0",
        "permissions": ["sidePanel", "tabs"],
        "action": {"default_title": "Panel Private"},
        "side_panel": {"default_path": "panel.html"},
    }))
    (folder / "panel.html").write_text(PANEL)
    (folder / "page.html").write_text("<!doctype html><title>own</title>")
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


def pages():
    """How far the widest page on screen reaches, from the window's left."""
    return max((f[0] + f[2] for f in panel()["pages"] if f), default=0)


def urls(): return [x["url"] for x in sv.sp("state")["tabs"]]


def opened(path): return sum(1 for u in urls() if u.rstrip("/").endswith(path))


def letIn(ext, on): sv.cmd({"do": "ext-private", "id": ext["id"], "on": on}); time.sleep(0.8)


def ui(**f): sv.cmd({"do": "ui", **f}); time.sleep(0.9)


def picture(name):
    if not PICTURES: return
    for look in ("light", "dark"):
        ui(look=look)
        sv.cmd({"do": "picture", "path": f"{PICTURES}/private-panel-{name}-{look}.png", "page": False})
    ui(look="system")


def main():
    t = sv.T()
    if PICTURES: os.makedirs(PICTURES, exist_ok=True)
    folder = make()
    try:
        sv.setup(sidebar=True); sv.launch()
        plain = sv.page("a")
        ext = add(folder, "Panel Private")
        page = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "page.html"})["id"]
        time.sleep(1.0)

        # The window's panel, asked for by the extension itself.
        sv.cmd({"do": "eval", "id": page, "js": "chrome.sidePanel.open({windowId: 1}); 1"})
        time.sleep(1.2)
        st = panel()
        t.ok("the panel is up beside an ordinary tab", st["shown"] and not st["held"]
             and st["content"]["kind"] == "page", st)
        beside = pages()
        picture("beside-a-tab")
        peval("window.__kept = 'yes'; 1")

        # A private tab opened behind: nothing of the panel changes until it
        # is the tab you are on.
        shy = sv.cmd({"do": "open", "url": f"{sv.BASE}/b", "private": True})["id"]
        time.sleep(1.0)
        st = panel()
        t.ok("a private tab behind changes nothing", st["shown"] and not st["held"], st)

        # That tab in front: the panel waits, and the page takes its room.
        sv.sp("select", id=shy); time.sleep(0.8)
        st = panel()
        t.ok("a private tab in front: the panel is held back", st["held"] and st["content"]["kind"] == "page", st)
        t.ok("held back, not closed: it is still the panel you opened",
             st["shown"] and st["content"]["url"].endswith("/panel.html"), st)
        t.ok("the page takes the room the panel had", pages() > beside, (pages(), beside))
        t.ok("its page is kept while it waits", peval("window.__kept") == "yes", peval("window.__kept"))
        picture("held-back")

        # Asked for again over that tab, by an extension not let in: nothing.
        sv.cmd({"do": "eval", "id": page, "js": "chrome.sidePanel.open({windowId: 1}); 1"})
        time.sleep(1.2)
        t.ok("sidePanel.open over a private tab opens no panel", panel()["held"], panel())
        t.ok("and no tab either", opened("/panel.html") == 0, urls())

        # Let into private tabs: the panel comes through where it waited.
        letIn(ext, True)
        st = panel()
        t.ok("let into private tabs: the panel is there", st["shown"] and not st["held"], st)
        t.ok("the same page, not loaded again", peval("window.__kept") == "yes"
             and st["content"]["url"].endswith("/panel.html") and st["title"] == "The panel",
             (peval("window.__kept"), st))

        # Shut out again, with that tab still in front.
        letIn(ext, False)
        t.ok("shut out again: held back where it stands", panel()["held"], panel())

        # Back on an ordinary tab: through, whatever the switch says.
        sv.sp("select", id=plain); time.sleep(0.8)
        st = panel()
        t.ok("back on an ordinary tab: the panel is through", st["shown"] and not st["held"], st)
        t.ok("and the page gave its room back", pages() == beside, (pages(), beside))

        # And the private tab again, once more held back.
        sv.sp("select", id=shy); time.sleep(0.8)
        t.ok("the private tab again: held back", panel()["held"], panel())

        # Closed by hand while it waits: closed for good, room and all.
        panel("close"); time.sleep(0.6)
        st = panel()
        t.ok("closed while held back: it is closed, not waiting", not st["shown"] and not st["held"]
             and st["content"]["kind"] == "none", st)
        sv.quit()
    finally:
        t.done(); sv.finish(); shutil.rmtree(work, ignore_errors=True)
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
