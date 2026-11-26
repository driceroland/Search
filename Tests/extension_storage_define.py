#!/usr/bin/env python3
"""An extension script defining a property on localStorage doesn't crash the
page it runs in (idea 1199), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/extension_storage_define.py`.
A copy of build/Search.app under a bundle id of its own runs hidden in a
world of its own (split_view.py's harness); all of it is removed afterwards.

WebKit's web process crashes, a null read in JSStorage::defineOwnProperty,
when a script defines a property on a Storage with `writable` and no
`value`. Fabric's web clipper injects a script into every page that does
`Object.defineProperty(localStorage, "getItem", { writable: true })`: the
page's process died, Search loaded the page again, Fabric injected again,
and every page reloaded in a loop. Two test extensions do the same, one
through scripting.executeScript (as Fabric) and one from a manifest content
script, with Reflect.defineProperty and Object.defineProperties beside it.
Checked: each page loads once, both scripts run to their end, the
executeScript result is still the extension's file's, a define on any other
object is untouched, and a define Chrome refuses still throws.
"""
import json
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from collections import Counter
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("extension-storage-define")
BUNDLE = "com.officecommun.search.storagedefine"
work = Path(tempfile.mkdtemp(prefix="search-storagedefine-"))

# What both scripts run in the page, as Fabric's capture.js does, then a
# report on the page's root element (shared DOM, readable from the page).
BODY = """
const out = {};
try { Object.defineProperty(localStorage, "getItem", { writable: true }); out.define = "ok"; } catch (e) { out.define = e.name; }
try { out.reflect = Reflect.defineProperty(sessionStorage, "setItem", { writable: true }); } catch (e) { out.reflect = e.name; }
try { Object.defineProperties(localStorage, { removeItem: { writable: true } }); out.defineAll = "ok"; } catch (e) { out.defineAll = e.name; }
try { Object.defineProperty(localStorage, "x", { get() { return 1; } }); out.accessor = "ok"; } catch (e) { out.accessor = e.name; }
const plain = {}; Object.defineProperty(plain, "a", { get() { return 7; } }); out.plain = plain.a;
document.documentElement.dataset[KEY] = JSON.stringify(out);
"""
INJECT = {
    "manifest.json": json.dumps({"manifest_version": 3, "name": "Define inject", "version": "1.0",
                                 "background": {"service_worker": "bg.js"}, "permissions": ["scripting", "tabs", "storage"],
                                 "host_permissions": ["http://127.0.0.1/*"]}),
    "bg.js": """
chrome.tabs.onUpdated.addListener((id, info, tab) => {
  if (info.status !== "complete" || !/^http:/.test(tab.url || "")) return;
  const tell = (v) => chrome.scripting.executeScript({ target: { tabId: id }, args: [JSON.stringify(v)],
    func: (v) => { document.documentElement.dataset.result = v; } });
  chrome.scripting.executeScript({ target: { tabId: id }, files: ["inject.js"] })
    .then((r) => tell(r && r[0] && r[0].result), (e) => tell("error: " + e.message));
});
""",
    "inject.js": "(() => { const KEY = 'injected';" + BODY + " return 'from inject.js'; })();",
    "page.html": "<!doctype html><title>Define inject</title>",
}
CONTENT = {
    "manifest.json": json.dumps({"manifest_version": 3, "name": "Define content", "version": "1.0",
                                 "content_scripts": [{"matches": ["http://127.0.0.1/*"], "js": ["content.js"], "run_at": "document_end"}]}),
    "content.js": "(() => { const KEY = 'content';" + BODY + "})();",
}

hits = Counter()


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        hits[self.path] += 1
        body = f"<!doctype html><title>{self.path}</title><p>{self.path}".encode()
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def log_message(self, *a): pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"


def probe_copy():
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def loaded(name, within=60):
    end = time.time() + within
    while time.time() < end:
        ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == name and x["loaded"]), None)
        if ext: return ext
        time.sleep(0.25)
    return None


def report(tab, key):
    try:
        v = sv.cmd({"do": "eval", "id": tab, "js": f"document.documentElement.dataset.{key} || ''"}).get("value")
        return json.loads(v) if v else None
    except (RuntimeError, ValueError):
        return None


def main():
    t = sv.T()
    for name, files in (("inject", INJECT), ("content", CONTENT)):
        folder = work / name
        folder.mkdir()
        for f, text in files.items(): (folder / f).write_text(text)
    sv.APP = probe_copy()
    try:
        sv.setup(sidebar=True)
        sv.launch()
        sv.cmd({"do": "ext-answer", "answer": "yes"})
        ids = {}
        for name, label in (("inject", "Define inject"), ("content", "Define content")):
            sv.cmd({"do": "ext-folder", "path": str(work / name), "yes": True})
            ext = loaded(label)
            t.ok(f"{name}: loads", ext is not None)
            if ext: ids[name] = ext["id"]
        time.sleep(2)
        tab = sv.sp("open", url=f"{BASE}/page")["resultID"]
        time.sleep(8)
        t.ok("the page loaded once, no crash and reload", hits["/page"] == 1, dict(hits))
        want = {"define": "ok", "reflect": True, "defineAll": "ok", "accessor": "TypeError", "plain": 7}
        for key in ("injected", "content"):
            got = report(tab, key)
            t.ok(f"{key}: ran to its end as in Chrome", got == want, got)
        result = report(tab, "result")
        t.ok("executeScript's result is still the extension file's", result == "from inject.js", result)
    finally:
        sv.finish()
        for kind in ("WebKit", "Caches", "HTTPStorages"):
            shutil.rmtree(Path.home() / "Library" / kind / BUNDLE, ignore_errors=True)
        shutil.rmtree(work, ignore_errors=True)
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
