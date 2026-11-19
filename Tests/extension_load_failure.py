#!/usr/bin/env python3
"""An extension that is switched on and doesn't start says so, and why (#1208).

Build first (`./build.sh`), then `python3 Tests/extension_load_failure.py`.
A hidden probe in a world of its own (split_view.py's harness):

- an unpacked Manifest V2 extension shaped like uBlock Origin's, with a
  background page that stays open (persistent) and webRequestBlocking,
  installs and starts: this Mac's WebKit takes a persistent background page,
  so that alone is no reason to refuse one;
- its installed copy is then broken on disk and the probe started again:
  the extension is still switched on, isn't running, and Settings has
  WebKit's reason for it (Bench "extensions" → failure);
- switched off, the reason goes.
"""
import json
import shutil
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("ext-load-failure")
work = Path(tempfile.mkdtemp(prefix="search-ext-load-failure-"))

MANIFEST = {
    "manifest_version": 2, "name": "Persistent", "version": "1.0", "description": "A persistent MV2 background page",
    "background": {"page": "background.html", "persistent": True},
    "browser_action": {"default_title": "Persistent", "default_popup": "popup.html"},
    "content_scripts": [{"matches": ["http://*/*", "https://*/*"], "js": ["content.js"], "all_frames": True,
                         "match_about_blank": True, "run_at": "document_start"}],
    "incognito": "split",
    "permissions": ["alarms", "contextMenus", "privacy", "storage", "tabs", "unlimitedStorage", "webNavigation",
                    "webRequest", "webRequestBlocking", "<all_urls>"],
    "web_accessible_resources": ["/web_accessible_resources/*"],
}
FILES = {
    "manifest.json": json.dumps(MANIFEST),
    "background.html": '<!doctype html><script src="bg.js"></script>',
    "bg.js": "chrome.storage.local.set({ up: Date.now() });",
    "content.js": "void 0;",
    "popup.html": "<!doctype html><p>popup",
}


def ours():
    return next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == "Persistent"), None)


def until(check, seconds=20):
    end = time.time() + seconds
    while time.time() < end:
        found = check()
        if found:
            return found
        time.sleep(0.25)
    return check()


def main():
    t = sv.T()
    folder = work / "ext"
    folder.mkdir()
    for name, body in FILES.items():
        (folder / name).write_text(body)
    try:
        sv.setup()
        sv.launch()
        sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
        ext = until(lambda: (lambda x: x if x and x["loaded"] else None)(ours()), 30)
        t.ok("a persistent MV2 background extension installs and starts", ext is not None, ours())
        if not ext:
            return t
        t.ok("nothing is reported against it", ext["failure"] == "" and ext["action"] == "Persistent", ext)
        page = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "popup.html"})["id"]
        key = "__up"
        time.sleep(2)
        sv.ev(page, f"window.{key}=null;try{{chrome.storage.local.get('up', v=>window.{key}=String((v&&v.up)||''))}}catch(e){{window.{key}='error: '+e}};1")
        up = until(lambda: sv.ev(page, f"window.{key}"), 10)
        t.ok("its background page ran", bool(up), up)

        # Broken on disk, then a launch: WebKit can't read it now.
        sv.quit()
        installed = Path(sv.SUPPORT, "Extensions", ext["id"], "manifest.json")
        t.ok("its installed copy is where expected", installed.exists(), str(installed))
        installed.write_text("{ not json")
        sv.launch()
        broken = until(lambda: (lambda x: x if x and x["failure"] else None)(ours()), 30) or ours()
        t.ok("still switched on, not running", broken and broken["enabled"] and not broken["loaded"], broken)
        t.ok(f"with WebKit's reason ({broken and broken['failure']!r})", broken and len(broken["failure"]) > 5, broken)

        sv.cmd({"do": "ext-enable", "id": ext["id"], "on": False})
        off = until(lambda: (lambda x: x if x and not x["enabled"] else None)(ours()), 5)
        t.ok("switched off, the reason goes", off and off["failure"] == "", off)
    finally:
        sv.finish()
        shutil.rmtree(work, ignore_errors=True)
    return t


if __name__ == "__main__":
    t = main()
    t.done()
    sys.exit(1 if t.failed else 0)
