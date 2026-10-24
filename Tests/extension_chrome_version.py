#!/usr/bin/env python3
"""The Chrome version extensions see is a current one (#685).

Build first (`./build.sh`), then `python3 Tests/extension_chrome_version.py`.
It runs a copy of build/Search.app under a bundle id of its own, hidden, in
a world of its own with split_view.py's harness; the copy, its WebKit
folders and the world are removed afterwards.

1Password asks for its popup to unlock (action.openPopup) only from Chrome
149, read from navigator.userAgent; Search said 140, and the 1Password
button in a field did nothing while 1Password was locked. An extension page
here reads what an extension reads.
"""
import json
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bug-chrome-version")
BUNDLE = "com.officecommun.search.chromeversion"
work = Path(tempfile.mkdtemp(prefix="search-chromeversion-"))
FILES = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "Version", "version": "1.0",
        "action": {"default_title": "Version"},
    }),
    "page.html": "<!doctype html><p>version",
}


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
    for name, body in FILES.items():
        (folder / name).write_text(body)
    sv.APP = probe_copy()
    try:
        sv.setup()
        sv.launch()
        sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
        ext = None
        for _ in range(60):
            ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == "Version" and x["loaded"]), None)
            if ext:
                break
            time.sleep(0.25)
        t.ok("the extension loads", ext is not None)
        if not ext:
            return t
        tid = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "page.html"})["id"]
        seen = None
        for _ in range(24):
            seen = json.loads(sv.ev(tid, "JSON.stringify({ua: navigator.userAgent, brands: navigator.userAgentData && navigator.userAgentData.brands})") or "null")
            if seen and "Chrome/" in (seen.get("ua") or ""):
                break
            time.sleep(0.25)
        major = int(re.search(r"Chrome/(\d+)", (seen or {}).get("ua") or "Chrome/0").group(1))
        t.ok("an extension sees Chrome 149 or later, as 1Password needs to open its popup", major >= 149, seen)
        brands = {b["brand"]: b["version"] for b in (seen or {}).get("brands") or []}
        t.ok("…and userAgentData says the same version", brands.get("Google Chrome") == str(major), brands)
    finally:
        sv.finish()
        for kind in ("WebKit", "Caches", "HTTPStorages"):
            shutil.rmtree(Path.home() / "Library" / kind / BUNDLE, ignore_errors=True)
        subprocess.run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", "-u", sv.APP], capture_output=True)
        shutil.rmtree(work, ignore_errors=True)
    return t


if __name__ == "__main__":
    t = main()
    t.done()
    sys.exit(1 if t.failed else 0)
