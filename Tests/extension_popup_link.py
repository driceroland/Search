#!/usr/bin/env python3
"""A link with target="_blank" in an extension's popup opens a tab (idea
972), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/extension_popup_link.py`.
It runs a copy of build/Search.app under a bundle id of its own, hidden, in
a world of its own with split_view.py's harness; the copy, its WebKit
folders and the world are removed afterwards.

Raindrop.io's popup signs in through a plain `<a href=… target="_blank">`.
In the popup's view (built from the extension's configuration) WebKit asked
for the link's policy and then never for a new view, so the click did
nothing: no tab, no window. The same link in a tab worked. What is checked,
with a local extension:

- a target="_blank" link in the popup opens one tab at its address, and
  the popup goes, as in Chrome;
- window.open from the popup still opens exactly one tab;
- the same link in the extension's page in a tab still opens one tab.

With SEARCH_RAINDROP=1 (needs the network) it also installs the real
Raindrop.io from the Web Store and clicks its popup's Sign in, without
signing in: the tab for app.raindrop.io/account/extension has to open.
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

sv.use("extension-popup-link")
BUNDLE = "com.officecommun.search.popuplink"
RAINDROP = "ldgfbffkinooeloadekpmfoklnobpien"
work = Path(tempfile.mkdtemp(prefix="search-popuplink-"))
PORT = sv.srv.server_port
BASE = f"http://127.0.0.1:{PORT}"
NAME = "LinkOut"

FILES = {
    "manifest.json": json.dumps({"manifest_version": 3, "name": NAME, "version": "1.0", "action": {"default_popup": "popup.html"}}),
    "popup.html": f"<!doctype html><body style='width:200px;height:80px'><a id=a href='{BASE}/from-popup' target=_blank>Sign in</a></body>",
    "page.html": f"<!doctype html><a id=a href='{BASE}/from-page' target=_blank>Go</a>",
}


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


def wait_popup(id, within=8):
    end = time.time() + within
    while time.time() < end:
        if popup(id): return True
        time.sleep(0.25)
    return False


def urls():
    return [x["url"] for x in sv.cmd({"do": "tabs"})["tabs"]]


def opened(before, prefix, within=6):
    """The tabs at prefix that weren't there before, once one shows up."""
    end = time.time() + within
    new = []
    while time.time() < end:
        now = urls()
        new = [u for u in now if u.startswith(prefix)]
        new = new[len([u for u in before if u.startswith(prefix)]):]
        if new: time.sleep(0.8); break
        time.sleep(0.25)
    now = urls()
    return [u for u in now if u.startswith(prefix)][len([u for u in before if u.startswith(prefix)]):]


def loaded(match, within=60):
    end = time.time() + within
    while time.time() < end:
        ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if match(x) and x["loaded"]), None)
        if ext: return ext
        time.sleep(0.25)
    return None


def open_popup(id, page):
    sv.cmd({"do": "select", "id": page}); time.sleep(0.5)
    if popup(id): return True
    sv.cmd({"do": "ext-press", "id": id})
    return wait_popup(id)


def raindrop(t, page):
    sv.cmd({"do": "ext-add", "id": RAINDROP, "yes": True})
    ext = loaded(lambda x: x["id"] == RAINDROP, 120)
    t.ok("Raindrop: installs and loads", ext is not None)
    if not ext: return
    time.sleep(3)
    text = ""
    if open_popup(RAINDROP, page):
        for _ in range(30):
            text = (popup(RAINDROP, "document.body ? document.body.innerText : ''") or {}).get("value") or ""
            if "Sign in" in text: break
            time.sleep(0.5)
    t.ok("Raindrop: its popup shows Sign in", "Sign in" in text, repr(text[:120]))
    before = urls()
    popup(RAINDROP, "[...document.querySelectorAll('a')].find((e) => /Sign in/.test(e.innerText)).click(); 1")
    new = opened(before, "https://app.raindrop.io/", 10)
    # It lands on its sign-in page, account/login?redirect=/account/extension.
    t.ok("Raindrop: Sign in opens its page in a tab", len(new) == 1 and "account" in new[0] and "extension" in new[0], new)


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
        ext = loaded(lambda x: x["name"] == NAME)
        t.ok("the extension loads", ext is not None)
        if not ext: return t
        id = ext["id"]
        page = sv.page("site")

        t.ok("its popup opens", open_popup(id, page))
        before = urls()
        time.sleep(1)  # loaded, not just answering
        popup(id, "document.getElementById('a').click(); 1")
        new = opened(before, f"{BASE}/from-popup")
        t.ok("a target=_blank link in the popup opens one tab at its address", new == [f"{BASE}/from-popup"], new)
        time.sleep(0.5)
        t.ok("… and the popup goes", popup(id) is None)

        t.ok("its popup opens again", open_popup(id, page))
        before = urls()
        popup(id, f"window.open('{BASE}/by-script', '_blank'); 1")
        new = opened(before, f"{BASE}/by-script")
        t.ok("window.open from the popup still opens one tab", new == [f"{BASE}/by-script"], new)

        tab = sv.cmd({"do": "ext-page", "id": id, "path": "page.html"})["id"]
        time.sleep(1.5)
        before = urls()
        sv.ev(tab, "document.getElementById('a').click(); 1")
        new = opened(before, f"{BASE}/from-page")
        t.ok("the same link in the extension's page in a tab opens one tab", new == [f"{BASE}/from-page"], new)

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
