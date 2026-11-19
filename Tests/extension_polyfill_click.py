#!/usr/bin/env python3
"""An extension's worker that loads webextension-polyfill still hears its
button, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/extension_polyfill_click.py`.
It runs a copy of build/Search.app under a bundle id of its own, in a world
of its own with split_view.py's harness, started hidden; the copy, its
WebKit folders and the world are removed afterwards.

webextension-polyfill doesn't take WebKit's `browser` for a native one (its
prototype isn't Object's), so it puts its own wrapper of `chrome` in
`globalThis.browser`. With that there, WebKit stopped handing the worker its
events: Cosmos's worker loads the polyfill, never heard action.onClicked,
and its window never opened, from its button or the one on an image (idea
696). The worker here does what the polyfill does. What is checked:

- the button press reaches the worker's action.onClicked;
- `browser` in the worker is still WebKit's, and a message still gets its
  answer.

With SEARCH_COSMOS=1 it also installs the real Cosmos extension from the Web
Store, presses its button over a page, and looks for its window there.
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

sv.use("ext-polyfill-click")
BUNDLE = "com.officecommun.search.extpolyfillclick"
COSMOS = "mgjneceglphcpbbfbhjplkpgfapebmdg"
work = Path(tempfile.mkdtemp(prefix="search-extpolyfillclick-"))

FILES = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "Polyfilled", "version": "1.0",
        "background": {"service_worker": "sw.js"},
        "action": {"default_title": "Polyfilled"},
        "permissions": ["storage"],
    }),
    # What webextension-polyfill's UMD wrapper does when `browser` isn't a
    # plain object: its wrapper of `chrome`, set on the global.
    "polyfill.js": "globalThis.browser = new Proxy(Object.create(chrome), {});",
    "sw.js": """
importScripts("polyfill.js");
chrome.action.onClicked.addListener((tab) => { chrome.storage.local.set({ clicked: tab ? tab.id : -1 }); });
chrome.runtime.onMessage.addListener((m, sender, reply) => {
  reply({ native: Object.getPrototypeOf(browser) !== Object.prototype && Object.getPrototypeOf(browser) !== chrome });
});
""",
    "page.html": "<!doctype html><p>page</p>",
}

# Whether something covers the page's top right, where Cosmos puts its window.
TOP_RIGHT = "(() => { const e = document.elementFromPoint(innerWidth - 60, 60); return e ? e.tagName : null; })()"


def probe_copy():
    """build/Search.app under a bundle id of its own, signed ad hoc."""
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def run(tid, js, within=10):
    """`js`, a promise, in the tab; its JSON, or "timeout"."""
    key = f"__r{int(time.time() * 1000)}"
    sv.ev(tid, f"window.{key}=null;Promise.resolve().then(()=>{js}).then(v=>window.{key}=JSON.stringify(v===undefined?null:v),"
               f"e=>window.{key}=JSON.stringify({{error:String(e)}}));1")
    end = time.time() + within
    while time.time() < end:
        value = sv.ev(tid, f"window.{key}")
        if value:
            return json.loads(value)
        time.sleep(0.25)
    return "timeout"


def loaded(match, within=60):
    end = time.time() + within
    while time.time() < end:
        ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if match(x) and x["loaded"]), None)
        if ext:
            return ext
        time.sleep(0.5)
    return None


def main():
    t = sv.T()
    folder = work / "ext"
    folder.mkdir()
    for name, body in FILES.items():
        (folder / name).write_text(body)
    sv.APP = probe_copy()
    try:
        sv.setup()
        sv.launch()
        sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
        ext = loaded(lambda x: x["name"] == "Polyfilled", 15)
        t.ok("the extension loads", ext is not None)
        if not ext:
            return t
        site = sv.page("site")
        time.sleep(1.5)
        sv.cmd({"do": "ext-press", "id": ext["id"]})
        time.sleep(2)
        page = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "page.html"})["id"]
        time.sleep(1)
        r = run(page, "chrome.storage.local.get('clicked')")
        t.ok("the button press reaches the worker's action.onClicked", isinstance(r, dict) and isinstance(r.get("clicked"), int), r)
        r = run(page, "chrome.runtime.sendMessage({ ask: 1 })")
        t.ok("the worker's `browser` is still WebKit's, and a message gets its answer", r == {"native": True}, r)

        if os.environ.get("SEARCH_COSMOS") == "1":
            sv.cmd({"do": "ext-answer", "answer": "yes"})
            sv.cmd({"do": "ext-add", "id": COSMOS, "yes": True})
            cosmos = loaded(lambda x: x["id"] == COSMOS, 90)
            t.ok("Cosmos loads", cosmos is not None)
            if cosmos:
                # A page in front for it to save (its scripts go into the
                # tab in front, once a second).
                site = sv.page("cosmos")
                time.sleep(5)
                before = sv.ev(site, TOP_RIGHT)
                sv.cmd({"do": "ext-press", "id": COSMOS})
                time.sleep(6)
                after = sv.ev(site, TOP_RIGHT)
                t.ok("Cosmos's button opens its window over the page", before == "HTML" and after == "DIV", (before, after))
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
