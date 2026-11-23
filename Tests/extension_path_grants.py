#!/usr/bin/env python3
"""An extension whose content scripts name narrower paths of a site it
already has whole runs each script once, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/extension_path_grants.py`.
It runs a copy of build/Search.app under a bundle id of its own, hidden, in
a world of its own with split_view.py's harness; the copy, its WebKit
folders and the world are removed afterwards.

WebKit copies an extension's content scripts once per granted pattern that
reaches a page. Enhancer for YouTube asks for *://www.youtube.com/* and has
scripts for /embed/*, /live_chat* and /shorts/* too; each was granted as a
pattern of its own, so on a watch page its scripts ran four times (four of
every button, four options tabs from one click, #1465). The same shape is
served here from 127.0.0.1. What is checked: on a page and on each narrower
path, every script that matches runs exactly once, and the ones that don't
match don't run.
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

sv.use("extension-path-grants")
BUNDLE = "com.officecommun.search.pathgrants"
work = Path(tempfile.mkdtemp(prefix="search-pathgrants-"))

SITE = "http://127.0.0.1/"
OTHER = "http://localhost/"
SCRIPTS = [
    # Enhancer for YouTube's entries, hosts swapped.
    {"matches": [SITE + "*"], "exclude_matches": [SITE + "embed/*"], "js": ["main.js"], "world": "MAIN", "run_at": "document_start"},
    {"matches": [SITE + "*"], "exclude_matches": [SITE + "embed/*"], "js": ["config.js", "page.js"], "world": "ISOLATED", "run_at": "document_start"},
    {"matches": [SITE + "embed/*", OTHER + "embed/*"], "js": ["embed_main.js"], "world": "MAIN", "run_at": "document_start", "all_frames": True},
    {"matches": [SITE + "embed/*", OTHER + "embed/*"], "js": ["config.js", "embed.js"], "world": "ISOLATED", "run_at": "document_start", "all_frames": True},
    {"matches": [SITE + "live_chat*"], "js": ["chat.js"], "world": "ISOLATED", "run_at": "document_start", "all_frames": True},
    {"matches": [SITE + "shorts/*"], "js": ["config.js", "shorts.js"], "world": "ISOLATED", "run_at": "document_start"},
]
NAMES = ["main", "config", "page", "embed_main", "embed", "chat", "shorts"]


def counter(name):
    return f";(() => {{ const d = document.documentElement; d.dataset.{name} = String(+(d.dataset.{name} || 0) + 1); }})();\n"


def probe_copy():
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def main():
    t = sv.T()
    folder = work / "ext"
    folder.mkdir()
    (folder / "manifest.json").write_text(json.dumps({
        "manifest_version": 3, "name": "Paths", "version": "1.0",
        "permissions": ["storage"],
        "host_permissions": [SITE + "*", OTHER + "*"],
        "background": {"service_worker": "sw.js"},
        "content_scripts": SCRIPTS,
    }))
    (folder / "sw.js").write_text("chrome.runtime.onMessage.addListener(() => {});")
    for name in NAMES:
        (folder / f"{name}.js").write_text(counter(name))
    sv.APP = probe_copy()
    try:
        sv.setup()
        sv.launch()
        sv.cmd({"do": "ext-answer", "answer": "yes"})
        sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
        ext = None
        for _ in range(60):
            ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == "Paths" and x["loaded"]), None)
            if ext: break
            time.sleep(0.25)
        t.ok("the extension loads", ext is not None)
        if not ext: return t
        time.sleep(2)
        want = {
            "watch?v=1": {"main": "1", "config": "1", "page": "1"},
            "embed/x": {"embed_main": "1", "config": "1", "embed": "1"},
            "live_chat?v=1": {"main": "1", "config": "1", "page": "1", "chat": "1"},
            "shorts/x": {"main": "1", "config": "2", "page": "1", "shorts": "1"},
        }
        for path, expected in want.items():
            tid = sv.sp("open", url=f"{sv.BASE}/{path}")["resultID"]
            found = {}
            for _ in range(20):
                time.sleep(0.4)
                found = json.loads(sv.ev(tid, "JSON.stringify(Object.assign({}, document.documentElement.dataset))") or "{}")
                if found == expected: break
            t.ok(f"/{path}: each matching script runs once", found == expected, found)
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
