#!/usr/bin/env python3
"""An extension's own frame takes the keys after its content script opens it
on a key press, as Vimium's Vomnibar does, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/extension_frame_focus.py`.
It runs a copy of build/Search.app under a bundle id of its own, hidden, in
a world of its own with split_view.py's harness; the copy, its WebKit
folders and the world are removed afterwards.

The content script answers T by putting the extension's page in a frame
over the site, focusing the frame, and asking the page to focus its box.
WebKit refused the box's focus() in a frame from another site until the
frame had a key or click of its own, so what was typed next went nowhere.
Checked: the letters typed after T land in the box, and Escape typed as
the first key reaches the box's own handler.
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

sv.use("extension-frame-focus")
BUNDLE = "com.officecommun.search.framefocus"
work = Path(tempfile.mkdtemp(prefix="search-framefocus-"))

FILES = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "Box", "version": "1.0",
        "content_scripts": [{"matches": ["<all_urls>"], "js": ["content.js"], "run_at": "document_idle"}],
        "web_accessible_resources": [{"resources": ["box.html", "box.js"], "matches": ["<all_urls>"]}],
    }),
    "content.js": """
let frame = null;
const say = (k, v) => document.documentElement.setAttribute('data-' + k, v);
say('ready', '1');
window.addEventListener('message', (e) => {
  if (e.data && e.data.box !== undefined) say('box', e.data.box);
  if (e.data && e.data.escape) say('escape', String(e.data.escape));
});
window.addEventListener('keydown', (e) => {
  if (e.key !== 't' || frame) return;
  e.preventDefault();
  frame = document.createElement('iframe');
  frame.src = chrome.runtime.getURL('box.html');
  frame.style.cssText = 'position:fixed;top:40px;left:40px;width:400px;height:80px;border:0;z-index:99999';
  frame.addEventListener('load', () => { frame.focus(); frame.contentWindow.postMessage('focus', '*'); });
  document.documentElement.appendChild(frame);
}, true);
""",
    "box.html": "<!doctype html><body style='margin:0'><input id=box autocomplete=off style='width:380px;font-size:18px'><script src=box.js></script></body>",
    "box.js": """
const box = document.getElementById('box');
let escapes = 0;
window.addEventListener('message', (e) => { if (e.data === 'focus') box.focus(); });
box.addEventListener('input', () => parent.postMessage({ box: box.value }, '*'));
box.addEventListener('keydown', (e) => { if (e.key === 'Escape') parent.postMessage({ escape: ++escapes }, '*'); });
""",
}


def probe_copy():
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def press(code, ch):
    sv.cmd({"do": "press", "code": code, "chars": ch, "mods": []})
    time.sleep(0.25)


def attr(page, name):
    return sv.cmd({"do": "eval", "id": page, "js": f"document.documentElement.getAttribute('data-{name}') || ''"}).get("value")


def has_keys(page):
    tab = next((x for x in sv.sp("state")["tabs"] if x["id"] == page), {})
    return tab.get("hasKeys") is True


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
            ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == "Box" and x["loaded"]), None)
            if ext: break
            time.sleep(0.25)
        t.ok("the extension loads", ext is not None)
        if not ext: return t
        page = sv.page("site")
        for _ in range(40):
            if attr(page, "ready") == "1": break
            time.sleep(0.25)
        t.ok("its content script runs on the page", attr(page, "ready") == "1")
        sv.cmd({"do": "click", "id": page, "selector": "body"})
        time.sleep(0.4)
        # The keys go to the window's first responder, and a tab opened a
        # moment ago doesn't always have it yet (the click above is the
        # page's own, which doesn't move it): T then never reached the page,
        # about one run in four, and the checks below failed with nothing in
        # the box. So the page is given the keys, as a click on it would.
        if not has_keys(page):
            sv.cmd({"do": "key", "id": page, "text": ""})
        t.ok("the page has the keys", has_keys(page))

        press(17, "t"); time.sleep(1.5)
        press(0, "a"); press(11, "b")
        time.sleep(0.6)
        t.ok("letters typed after T land in the extension's box", attr(page, "box") == "ab", attr(page, "box"))
        press(53, "\u001b"); time.sleep(0.5)
        t.ok("Escape reaches the box's own handler", attr(page, "escape") == "1", attr(page, "escape"))
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
