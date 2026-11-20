#!/usr/bin/env python3
"""Stylus's button opens a popup that works, and its style manager — in a
hidden probe. Needs the network: Stylus comes from the Chrome Web Store.

Build first (`./build.sh`), then `python3 Tests/extension_stylus.py`. It
runs a copy of build/Search.app under a bundle id of its own, hidden, in a
world of its own with split_view.py's harness; the copy, its WebKit
folders and the world are removed afterwards.

In 1.0.15 a click on Stylus's button seemed to do nothing: its popup
loaded but stayed at its first frame ("Toggle styles" and ⚙), waiting for
its worker, which it reaches over a port handed to
navigator.serviceWorker. Nothing in it answered, and its manager button
opened no tab. Fixed in 1.0.16 (#1258). What is checked:

- the popup comes up with its worker's data: the site it is on, and
  "no styles" for it;
- it is laid out at a popup's size, not a sliver;
- its manager button opens Stylus's manager in a tab;
- the manager fills its list from the worker.
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

sv.use("extension-stylus")
BUNDLE = "com.officecommun.search.stylus"
STYLUS = "clngdbkpkpeebahjckkjfobafhncgmne"
work = Path(tempfile.mkdtemp(prefix="search-stylus-"))


def probe_copy():
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def popup(js):
    try:
        return sv.cmd({"do": "ext-popup", "id": STYLUS, "js": js}).get("value")
    except RuntimeError:
        return None


def main():
    t = sv.T()
    sv.APP = probe_copy()
    try:
        sv.setup()
        sv.launch()
        sv.cmd({"do": "ext-answer", "answer": "yes"})
        sv.cmd({"do": "ext-add", "id": STYLUS, "yes": True})
        ext = None
        for _ in range(240):
            ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["id"] == STYLUS and x["loaded"]), None)
            if ext: break
            time.sleep(0.5)
        t.ok("Stylus installs from the store and loads", ext is not None)
        if not ext: return t
        site = sv.page("a")
        sv.cmd({"do": "go", "id": site, "url": "https://example.com"})
        time.sleep(3)

        sv.cmd({"do": "ext-press", "id": STYLUS})
        state = {}
        for _ in range(40):
            raw = popup("JSON.stringify({cls: document.documentElement.className, text: document.body ? document.body.innerText : '', w: innerWidth, h: innerHeight})")
            state = json.loads(raw) if raw else {}
            if "has-favicons" in state.get("cls", ""): break
            time.sleep(0.25)
        t.ok("the popup opens", bool(state), state)
        t.ok("…with its worker's data", "has-favicons" in state.get("cls", "") and "no-styles" in state.get("cls", ""), state.get("cls"))
        t.ok("…naming the site it is on", "example.com" in state.get("text", ""), state.get("text", "")[:200])
        time.sleep(5)  # shown at its measured size
        size = json.loads(popup("JSON.stringify([innerWidth, innerHeight])") or "[0,0]")
        t.ok("…at a popup's size", size[0] >= 200 and size[1] >= 60, size)

        before = {x["url"] for x in sv.sp("state")["tabs"]}
        clicked = popup("(() => { const b = document.querySelector('#popup-manage-button'); if (!b) return false; b.click(); return true })()")
        manager = None
        for _ in range(40):
            manager = next((x for x in sv.sp("state")["tabs"] if x["url"] not in before and "/manage.html" in x["url"]), None)
            if manager: break
            time.sleep(0.25)
        t.ok("its manager button opens the manager in a tab", clicked and manager is not None, clicked)
        if manager:
            filled = None
            for _ in range(40):
                filled = sv.ev(manager["id"], "document.documentElement.className + '|' + !!document.querySelector('#installed')")
                if filled and "|true" in filled and "loading" not in filled: break
                time.sleep(0.25)
            t.ok("…which fills from the worker", bool(filled) and "|true" in filled and "loading" not in filled, filled)
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
