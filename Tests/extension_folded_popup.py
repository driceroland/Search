#!/usr/bin/env python3
"""An extension's popup from its keyboard shortcut, with the column or the
strip folded away, in a hidden probe.

Build first (`./build.sh debug`), then
`python3 Tests/extension_folded_popup.py`. It runs a copy of
build/Search.app under a bundle id of its own, hidden, in a world of its own
with split_view.py's harness; the copy, its WebKit folders and the world are
removed afterwards.

Folded away (⌘S), the column keeps its buttons in the window, slid out past
its left edge, and the strip past its top. A popup hung from an extension's
button there opened off the window, where nobody saw it: Raindrop.io's
shortcut did nothing while the sidebar was hidden. The extension here does
what Raindrop does: a popup with a query in its address (index.html?action),
opened by _execute_action, and by a command whose worker sets the popup to
another page and opens it (action.setPopup, action.openPopup). For the
column and the strip, out and folded, what is checked:

- each key opens the popup, with the page it asked for;
- the popup hangs from something in sight: the button, when it is in the
  window, else the window itself — never a button slid out past its edge.

A probe can't see a popover come up (the app is hidden), so where it hangs
is what is checked; that it then shows is AppKit's part.

With SEARCH_RAINDROP=1 it also installs Raindrop.io from the Web Store
(no account): its popup renders its sign-in, its "Save page" menu item opens
the popup at its add page, its commands are there, and its welcome tab
opens once, on install, and not again on a relaunch.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("extension-folded-popup")
BUNDLE = "com.officecommun.search.foldedpopup"
RAINDROP = "ldgfbffkinooeloadekpmfoklnobpien"
work = Path(tempfile.mkdtemp(prefix="search-foldedpopup-"))
NAME = "Folded"

FILES = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": NAME, "version": "1.0",
        "action": {"default_popup": "popup.html?action"},
        "permissions": ["storage"],
        "background": {"service_worker": "background.js"},
        "commands": {
            "_execute_action": {"suggested_key": {"default": "Alt+Shift+Y"}},
            "save_page": {"suggested_key": {"default": "Alt+Shift+U"}, "description": "Save"},
        },
    }),
    # Raindrop's save_page, step for step.
    "background.js": """
chrome.commands.onCommand.addListener(async (command) => {
  if (command !== "save_page") return;
  const popup = chrome.runtime.getManifest().action.default_popup;
  await chrome.action.setPopup({ popup: popup + "#/add" });
  try { await chrome.action.openPopup(); } finally { await chrome.action.setPopup({ popup }); }
});
""",
    "popup.html": "<!doctype html><title>Folded</title><body style='width:200px;height:100px'>Popup</body>",
}

KEYS = {"_execute_action": (16, "y", ["opt", "shift"], ""), "save_page": (32, "u", ["opt", "shift"], "#/add")}


def probe_copy():
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def popup(id, js="location.href"):
    try:
        return sv.cmd({"do": "ext-popup", "id": id, "js": js})
    except RuntimeError:
        return None


def wait_popup(id, within=6):
    end = time.time() + within
    while time.time() < end:
        r = popup(id)
        if r: return r
        time.sleep(0.25)
    return None


def close(id):
    if popup(id): sv.cmd({"do": "ext-press", "id": id}); time.sleep(0.5)


def in_sight(placement):
    if placement.get("from") == "window": return True
    return placement.get("from") == "view" and placement.get("onWindow") is True and placement.get("hidden") is False


def loaded(match, within=60):
    end = time.time() + within
    while time.time() < end:
        ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if match(x) and x["loaded"]), None)
        if ext: return ext
        time.sleep(0.25)
    return None


def raindrop(t, page):
    sv.cmd({"do": "ext-add", "id": RAINDROP, "yes": True})
    ext = loaded(lambda x: x["id"] == RAINDROP, 120)
    t.ok("Raindrop: installs and loads", ext is not None)
    if not ext: return
    time.sleep(3)
    welcome = lambda: sum(1 for x in sv.cmd({"do": "tabs"})["tabs"] if x["url"].startswith(f"chrome-extension://{RAINDROP}/welcome/"))
    t.ok("Raindrop: its welcome tab opens on install", welcome() == 1, welcome())
    t.ok("Raindrop: its commands are there", {"_execute_action", "save_page", "execute_side_panel"} <= {c["id"] for c in ext.get("commands", [])}, ext.get("commands"))
    sv.cmd({"do": "select", "id": page}); time.sleep(1)
    close(RAINDROP)
    sv.cmd({"do": "ext-press", "id": RAINDROP})
    text = ""
    if wait_popup(RAINDROP):
        for _ in range(30):
            text = (popup(RAINDROP, "document.body ? document.body.innerText : ''") or {}).get("value") or ""
            if "Sign in" in text: break
            time.sleep(0.5)
    t.ok("Raindrop: its popup renders its sign-in", "Sign in" in text, repr(text[:120]))
    close(RAINDROP)
    menu = sv.cmd({"do": "linkmenu", "id": page, "x": 200, "y": 200, "pick": "Save page"}).get("menu", [])
    t.ok("Raindrop: its page menu has Save page", "Save page" in menu, menu)
    r = wait_popup(RAINDROP, 8)
    t.ok("Raindrop: Save page opens the popup at its add page", r is not None and "add%3Flink" in (r.get("value") or ""), r and r.get("value"))
    close(RAINDROP)
    sv.quit(); time.sleep(1)
    sv.launch()
    loaded(lambda x: x["id"] == RAINDROP)
    time.sleep(8)
    t.ok("Raindrop: no welcome tab again on a relaunch", welcome() <= 1, welcome())


def main():
    t = sv.T()
    folder = work / "ext"
    folder.mkdir()
    for name, body in FILES.items(): (folder / name).write_text(body)
    sv.APP = probe_copy()
    try:
        sv.setup(sidebar=True)
        sv.launch()
        sv.cmd({"do": "ext-answer", "answer": "yes"})
        sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
        ext = loaded(lambda x: x["name"] == NAME)
        t.ok("the extension loads", ext is not None)
        if not ext: return t
        id = ext["id"]
        keys = {c["id"]: c["key"] for c in ext.get("commands", [])}
        t.ok("its keys are its own", keys.get("_execute_action") == "⌥⇧Y" and keys.get("save_page") == "⌥⇧U", keys)
        sv.cmd({"do": "ext-pin", "id": id, "on": True})
        page = sv.page("site")
        time.sleep(1)
        for label, ui in [("column", {"sidebar": True, "folded": False}), ("column folded", {"sidebar": True, "folded": True}),
                          ("strip", {"sidebar": False, "folded": False}), ("strip folded", {"sidebar": False, "folded": True})]:
            sv.cmd({"do": "ui", **ui}); time.sleep(1.2)
            for command, (code, chars, mods, hash) in KEYS.items():
                close(id)
                sv.cmd({"do": "press", "code": code, "chars": chars, "mods": mods})
                r = wait_popup(id)
                t.ok(f"{label}: {command} opens the popup", r is not None and (r.get("value") or "").endswith("popup.html?action" + hash),
                     r and r.get("value"))
                placement = (r or {}).get("placement", {})
                t.ok(f"{label}: {command}'s popup hangs in sight", in_sight(placement), placement)
                if not ui["folded"]:
                    t.ok(f"{label}: {command}'s popup hangs from its button", placement.get("from") == "view", placement)
        close(id)
        sv.cmd({"do": "ui", "sidebar": True, "folded": False}); time.sleep(1)
        if os.environ.get("SEARCH_RAINDROP"): raindrop(t, page)
    finally:
        sv.finish()
        for kind in ("WebKit", "Caches", "HTTPStorages"):
            shutil.rmtree(Path.home() / "Library" / kind / BUNDLE, ignore_errors=True)
        shutil.rmtree(work, ignore_errors=True)
    return t


if __name__ == "__main__":
    result = main()
    result.done()
    sys.exit(1 if result.failed else 0)
