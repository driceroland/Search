#!/usr/bin/env python3
"""An extension whose background is a page isn't restarted for nothing, in a
hidden probe.

Build first (`./build.sh`), then `python3 Tests/extension_background_page.py`.
It runs a copy of build/Search.app under a bundle id of its own, in a world
of its own with split_view.py's harness, started hidden; the copy, its
WebKit folders and the world are removed afterwards.

A manifest that names scripts beside its worker (Language Reactor's) gets a
background page from WebKit. The shim's check that the worker still answers
ran there too: the background page asked itself, never heard back, and the
browser restarted the extension, over and over. What is checked:

- a background page that sends messages isn't restarted;
- it keeps running: its count of messages it sent goes on.
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

sv.use("ext-background-page")
BUNDLE = "com.officecommun.search.extbackgroundpage"
work = Path(tempfile.mkdtemp(prefix="search-extbackgroundpage-"))

FILES = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "BackgroundPage", "version": "1.0",
        "background": {"service_worker": "bg.js", "scripts": ["bg.js"]},
        "permissions": ["storage"],
    }),
    # Sends a message every second, as Language Reactor's background does,
    # and counts them where a page can read it.
    "bg.js": """
let sent = 0;
const started = Date.now();
setInterval(() => {
  sent += 1;
  chrome.runtime.sendMessage({ tick: sent }).catch(() => {});
  chrome.storage.local.set({ sent, started });
}, 1000);
""",
    "page.html": "<!doctype html><p>page</p>",
}


def probe_copy():
    """build/Search.app under a bundle id of its own, signed ad hoc."""
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def stored(tid):
    key = f"__r{int(time.time() * 1000)}"
    sv.ev(tid, f"window.{key}=null;chrome.storage.local.get(null).then(v=>window.{key}=JSON.stringify(v));1")
    for _ in range(20):
        value = sv.ev(tid, f"window.{key}")
        if value:
            return json.loads(value)
        time.sleep(0.25)
    return {}


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
        ext = None
        for _ in range(60):
            ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == "BackgroundPage" and x["loaded"]), None)
            if ext:
                break
            time.sleep(0.25)
        t.ok("the extension loads", ext is not None)
        if not ext:
            return t
        page = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "page.html"})["id"]
        time.sleep(2)
        first = stored(page)
        time.sleep(25)
        later = stored(page)
        reported = next(x for x in sv.cmd({"do": "extensions"})["extensions"] if x["id"] == ext["id"]).get("reported", [])
        t.ok("a background page that sends messages isn't restarted",
             not any("restarted" in r for r in reported), reported)
        t.ok("it keeps running, the same one", later.get("started") == first.get("started") and later.get("sent", 0) > first.get("sent", 0) + 15,
             (first, later))
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
