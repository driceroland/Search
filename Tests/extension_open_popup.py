#!/usr/bin/env python3
"""A popup the extension opens itself, from its button's click, in a hidden
probe.

Build first (`./build.sh`), then `python3 Tests/extension_open_popup.py`.
It runs a copy of build/Search.app under a bundle id of its own, hidden, in
a world of its own with split_view.py's harness; the copy, its WebKit
folders and the world are removed afterwards.

Inoreader keeps no popup in its manifest. A click reaches its worker
(action.onClicked), which asks for its site again (permissions.request),
sets the popup, opens it (action.openPopup) and unsets it at once, so the
next click comes back to the worker. In Search the click did nothing you
could see. What is checked:

- the click reaches the worker, and each step after it answers;
- the popup opens, and is still up a moment after the worker unset it;
- the button closes it, and the click after that opens it again.
"""
import json
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("extension-open-popup")
BUNDLE = "com.officecommun.search.openpopup"
work = Path(tempfile.mkdtemp(prefix="search-openpopup-"))

FILES = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "Opens", "version": "1.0",
        "action": {"default_popup": ""},
        "permissions": ["storage"],
        "host_permissions": ["*://*.example.com/*"],
        "background": {"service_worker": "background.js"},
    }),
    # Inoreader's handler, step for step, each one written down.
    "background.js": """
const steps = [];
const note = (s) => { steps.push(s); return chrome.storage.local.set({ steps }); };
chrome.action.onClicked.addListener((tab) => {
  note("clicked");
  chrome.permissions.request({ origins: ["*://*.example.com/*"] }).then(async (granted) => {
    await note("granted " + granted);
    if (!granted) return;
    try {
      await chrome.action.setPopup({ popup: "popup.html" }); await note("set");
      await chrome.action.openPopup(); await note("opened");
      await chrome.action.setPopup({ popup: "" }); await note("unset");
    } catch (e) { await note("error " + (e && e.message || e)); }
  }).catch((e) => note("request failed " + (e && e.message || e)));
});
""",
    "popup.html": "<!doctype html><title>Opened</title><body style='width:200px;height:100px'>Opened</body>",
}


def probe_copy():
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def popup_title(id):
    try:
        return sv.cmd({"do": "ext-popup", "id": id, "js": "document.title"}).get("value")
    except RuntimeError:
        return None


def steps(page):
    js = "(() => { try { chrome.storage.local.get('steps').then((r) => window.__s = r.steps || []); } catch (e) {} return JSON.stringify(window.__s || []); })()"
    try:
        return json.loads(sv.cmd({"do": "eval", "id": page, "js": js}).get("value") or "[]")
    except (RuntimeError, TypeError, ValueError):
        return []


def main():
    t = sv.T()
    folder = work / "ext"
    folder.mkdir()
    for name, body in FILES.items(): (folder / name).write_text(body)
    sv.APP = probe_copy()
    try:
        sv.setup()
        sv.launch()
        sv.cmd({"do": "ext-answer", "answer": "yes"})
        sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
        ext = None
        for _ in range(60):
            ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == "Opens" and x["loaded"]), None)
            if ext: break
            time.sleep(0.25)
        t.ok("the extension loads", ext is not None)
        if not ext: return t
        sv.cmd({"do": "ext-pin", "id": ext["id"], "on": True})
        sv.page("site")
        time.sleep(1)

        sv.cmd({"do": "ext-press", "id": ext["id"]})
        title = None
        for _ in range(20):
            title = popup_title(ext["id"])
            if title == "Opened": break
            time.sleep(0.25)
        time.sleep(1.5)
        still = popup_title(ext["id"])

        page = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "popup.html"})["id"]
        done = []
        for _ in range(12):
            done = steps(page)
            if "unset" in done or any(s.startswith(("error", "request failed")) for s in done): break
            time.sleep(0.25)
        t.ok("the click reaches the worker", "clicked" in done, done)
        t.ok("the site is granted again", "granted true" in done, done)
        t.ok("openPopup answers", "opened" in done, done)
        t.ok("the popup opens", title == "Opened", title)
        t.ok("…and stays up after the worker unsets it", still == "Opened", still)

        # As in Chrome: the button closes its popup, and the next click
        # goes to the worker again, which opens it again.
        sv.cmd({"do": "ext-press", "id": ext["id"]}); time.sleep(1)
        t.ok("a second click closes it", popup_title(ext["id"]) is None)
        sv.cmd({"do": "ext-press", "id": ext["id"]})
        again = None
        for _ in range(20):
            again = popup_title(ext["id"])
            if again == "Opened": break
            time.sleep(0.25)
        t.ok("a third opens it again", again == "Opened", again)
    finally:
        sv.finish()
        for kind in ("WebKit", "Caches", "HTTPStorages"):
            shutil.rmtree(Path.home() / "Library" / kind / BUNDLE, ignore_errors=True)
        shutil.rmtree(work, ignore_errors=True)
    return t


if __name__ == "__main__":
    t = main()
    t.done()
    sys.exit(1 if t.failed else 0)
