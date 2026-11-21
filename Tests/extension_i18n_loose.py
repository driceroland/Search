#!/usr/bin/env python3
"""An extension that reads chrome.i18n.getMessage loose gets its text — in a
hidden probe. Needs the network: Monarch Money | Retail purchase sync comes
from the Chrome Web Store.

Build first (`./build.sh`), then `python3 Tests/extension_i18n_loose.py`. It
runs a copy of build/Search.app under a bundle id of its own, hidden, in a
world of its own; the copy, its WebKit folders and the world are removed.

Its bundle does `const t = chrome.i18n.getMessage; t("key")`. WebKit's
function answered null off its object, so the options page drew with every
label, heading and button title blank. What is checked: a loose getMessage
(on chrome and browser) answers, and the options page has text.
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

sv.use("extension-monarch")
BUNDLE = "com.officecommun.search.monarch"
ID = "imfcckkmcklambpijbgcebggegggkgla"
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
        return sv.cmd({"do": "ext-popup", "id": ID, "js": js}).get("value")
    except RuntimeError:
        return None


def main():
    t = sv.T()
    sv.APP = probe_copy()
    try:
        sv.setup()
        sv.launch()
        sv.cmd({"do": "ext-answer", "answer": "yes"})
        sv.cmd({"do": "ext-add", "id": ID, "yes": True})
        ext = None
        for _ in range(240):
            ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["id"] == ID and x["loaded"]), None)
            if ext: break
            time.sleep(0.5)
        t.ok("the extension installs from the store and loads", ext is not None)
        if not ext: return t
        for opt in ('options.html','options/options.html','settings.html'):
            try:
                pid = sv.cmd({'do':'ext-page','id':ID,'path':opt})['id']
            except Exception as e:
                continue
            time.sleep(4)
            raw = sv.ev(pid, 'JSON.stringify([(()=>{const g=chrome.i18n.getMessage; return g("loading")})(), (()=>{const g=browser.i18n.getMessage; return g("loading")})(), document.getElementById("root").innerText.length])')
            got = json.loads(raw)
            t.ok("a loose chrome.i18n.getMessage answers", got[0] == "Loading...", got)
            t.ok("a loose browser.i18n.getMessage answers", got[1] == "Loading...", got)
            t.ok("the options page has its text", got[2] > 200, got)
            break
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
