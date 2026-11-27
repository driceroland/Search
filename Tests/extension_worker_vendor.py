#!/usr/bin/env python3
"""A module worker that sets navigator.vendor starts, as in Chrome (idea
1348), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/extension_worker_vendor.py`.
It runs a copy of build/Search.app under a bundle id of its own, hidden, in
a world of its own with split_view.py's harness; the copy, its WebKit
folders and the world are removed afterwards.

ClickUp Brain's worker is a module, so strict, and its first lines say
`self.navigator.vendor = 'Google Inc.'`. Chrome's worker has no vendor (the
spec gives it to windows alone), so that makes a property of its own. The
shim gave every navigator, a worker's too, a vendor with a getter and no
setter, and the assignment threw "Attempted to assign to readonly
property": the worker never started, no onboarding tab, and the toolbar
button opened nothing. What is checked, with a local extension:

- its module worker, which sets navigator.vendor first, starts and answers;
- the worker still reads Chrome's user agent from the shim;
- an extension page still reads navigator.vendor as Chrome's.
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

sv.use("extension-worker-vendor")
BUNDLE = "com.officecommun.search.workervendor"
work = Path(tempfile.mkdtemp(prefix="search-workervendor-"))
NAME = "Vendor Setter"

FILES = {
    "manifest.json": json.dumps({"manifest_version": 3, "name": NAME, "version": "1.0",
                                 "background": {"service_worker": "sw.js", "type": "module"}}),
    "sw.js": """self.navigator.vendor = 'Google Inc.';
chrome.runtime.onMessage.addListener((m, sender, reply) => {
  reply({ vendor: navigator.vendor, chrome: / Chrome\\//.test(navigator.userAgent) });
});
""",
    "page.html": "<!doctype html><p>page</p>",
}


def probe_copy():
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


def main():
    t = sv.T()
    folder = work / "ext"
    folder.mkdir()
    for name, body in FILES.items(): (folder / name).write_text(body)
    sv.APP = probe_copy()
    try:
        sv.setup()
        sv.launch()
        sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
        ext = None
        for _ in range(60):
            ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == NAME and x["loaded"]), None)
            if ext: break
            time.sleep(0.25)
        t.ok("the extension loads", ext is not None)
        if not ext: return t
        tid = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "page.html"})["id"]
        time.sleep(1.5)
        r = run(tid, "chrome.runtime.sendMessage({ask: 'vendor'})")
        t.ok("its module worker, which sets navigator.vendor first, starts and answers",
             isinstance(r, dict) and r.get("vendor") == "Google Inc.", r)
        t.ok("the worker still reads Chrome's user agent", isinstance(r, dict) and r.get("chrome") is True, r)
        reported = next(x for x in sv.cmd({"do": "extensions"})["extensions"] if x["id"] == ext["id"]).get("reported") or []
        t.ok("nothing reported about a read-only property", not any("readonly" in str(x) for x in reported), reported)
        t.ok("an extension page still reads navigator.vendor as Chrome's", sv.ev(tid, "navigator.vendor") == "Google Inc.")
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
