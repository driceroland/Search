#!/usr/bin/env python3
"""A freshly installed extension hears runtime.onInstalled("install") — in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/extension_install_event.py`.
Same harness as extension_ubol.py: a copy of build/Search.app under a
bundle id of its own, in a world of its own, started hidden; the copy, its
WebKit folders and the world are removed afterwards.

WebKit can tell a fresh install as a browser start: onStartup, and no
onInstalled. The first extension installed in each launch got that, and an
extension that sets itself up only on "install" was never set up. And
WebKit hands events over while a worker's importScripts runs, so a worker
whose listeners sit in a file it imports missed them. A local extension
with its listeners in an imported file, installed first in the launch:

- hears onInstalled("install") once, and no onStartup;
- reloaded, hears no second "install".
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

sv.use("sec-install-event")
BUNDLE = "com.officecommun.search.installevent"
work = Path(tempfile.mkdtemp(prefix="search-install-event-"))

FILES = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "InstallHeard", "version": "1.0",
        "permissions": ["storage"],
        "background": {"service_worker": "sw.js"},
    }),
    "sw.js": """
const me = Math.random().toString(36).slice(2, 8);
const note = (what) => chrome.storage.local.get('heard').then((r) =>
  chrome.storage.local.set({ heard: [...(r.heard || []), [me, what]] }));
// The listeners are in a file the worker imports.
importScripts('listen.js');
""",
    "listen.js": """
chrome.runtime.onInstalled.addListener((d) => note('installed:' + d.reason));
chrome.runtime.onStartup.addListener(() => note('startup'));
""",
    "page.html": "<!doctype html><title>page</title>",
}


def probe_copy():
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def wait_for(name, within=30):
    end = time.time() + within
    while time.time() < end:
        ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == name and x["loaded"]), None)
        if ext:
            return ext
        time.sleep(0.25)
    return None


def read(page, js, within=10):
    """A promise's value in one of the extension's pages, as JSON."""
    end = time.time() + within
    while time.time() < end:
        try:
            if sv.ev(page, "typeof chrome !== 'undefined' && !!(chrome.storage && chrome.storage.local)"):
                break
        except RuntimeError:
            pass
        time.sleep(0.25)
    sv.ev(page, "window.__o = null; Promise.resolve(" + js + ").then((v) => window.__o = JSON.stringify(v ?? null),"
                " (e) => window.__o = JSON.stringify({ error: String(e && e.message || e) })); 1")
    while time.time() < end:
        got = sv.ev(page, "window.__o")
        if isinstance(got, str):
            return json.loads(got)
        time.sleep(0.25)
    return None


def heard(page, within=6):
    """What the worker noted, once it has noted something (or within runs out)."""
    end = time.time() + within
    events = []
    while time.time() < end:
        events = [what for _, what in (read(page, "chrome.storage.local.get('heard').then((r) => r.heard || [])") or [])]
        if events:
            break
        time.sleep(0.25)
    return events


def main():
    t = sv.T()
    sv.APP = probe_copy()
    try:
        sv.setup()
        sv.launch()
        folder = work / "install-heard"
        folder.mkdir()
        for name, body in FILES.items():
            (folder / name).write_text(body)
        sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
        ext = wait_for("InstallHeard")
        t.ok("the extension loads, the first installed in this launch", ext is not None)
        if not ext:
            return t
        page = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "page.html"})["id"]
        heard(page)
        time.sleep(1)
        events = heard(page)
        print(f"       heard: {events}")
        t.ok("a fresh install hears onInstalled(\"install\") once", events.count("installed:install") == 1, events)
        t.ok("… and no onStartup", "startup" not in events, events)
        sv.cmd({"do": "close", "id": page})

        sv.cmd({"do": "ext-reload", "id": ext["id"]})
        ext = wait_for("InstallHeard")
        time.sleep(2)
        page = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "page.html"})["id"]
        events = heard(page)
        print(f"       heard, after a reload: {events}")
        t.ok("reloaded, it hears no second \"install\"", events.count("installed:install") == 1, events)
        sv.cmd({"do": "close", "id": page})
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
