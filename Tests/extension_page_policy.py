#!/usr/bin/env python3
"""A Manifest V3 extension's own pages keep Chrome's minimum script policy — in a hidden probe.

Build first (`./build.sh debug`), then, hidden and under the probe lock:
`lockf -t 900 /private/tmp/claude-501/search-probe.lock python3 Tests/extension_page_policy.py`.
Same harness as extension_sandbox_pages.py: a copy of build/Search.app under
a bundle id of its own, in a world of its own, started hidden; the copy, its
WebKit folders and the world are removed afterwards.

Chrome holds every Manifest V3 extension page to `script-src 'self'
'wasm-unsafe-eval'; object-src 'self'` whatever else the manifest's
extension_pages policy says. Local extensions:

- one whose policy names no script-src, with and without sandbox pages: its
  pages refuse eval, new Function and inline script, still run their own
  scripts and still run WebAssembly; its sandbox page still evals;
- one with WebKit's own policy, and one with Chrome's usual one: their pages
  run, reach the extension's APIs and storage, and refuse eval as before.
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

sv.use("sec-page-policy")
BUNDLE = "com.officecommun.search.pagepolicy"
work = Path(tempfile.mkdtemp(prefix="search-page-policy-"))

# The smallest WebAssembly module there is.
PAGE_JS = """
window.own = { ran: true, id: !!(chrome.runtime && chrome.runtime.id) };
window.got = [];
window.addEventListener('message', (e) => window.got.push(Object.assign({ sender: e.origin }, e.data)));
try { window.own.eval = eval('1 + 1'); } catch (e) { window.own.eval = 'refused'; }
try { window.own.fn = new Function('return 1')(); } catch (e) { window.own.fn = 'refused'; }
WebAssembly.compile(new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0])).then(() => { window.own.wasm = 'ran'; }, () => { window.own.wasm = 'refused'; });
chrome.storage.local.set({ k: 'v' }).then(() => chrome.storage.local.get('k')).then((r) => { window.own.storage = r.k; }, () => { window.own.storage = 'refused'; });
document.addEventListener('DOMContentLoaded', () => {
  const inline = document.createElement('script');
  inline.textContent = "window.own.inline = 'ran'";
  document.head.appendChild(inline);
});
"""
SANDBOX_JS = """
const r = { origin: String(self.origin) };
try { r.eval = eval('40 + 2'); } catch (e) { r.eval = 'refused'; }
parent.postMessage(r, '*');
"""


def package(name, policy=None, sandbox=False):
    manifest = {
        "manifest_version": 3, "name": name, "version": "1.0",
        "description": "Tries what its pages may run.",
        "permissions": ["storage"],
        "background": {"service_worker": "sw.js"},
    }
    if policy is not None:
        manifest["content_security_policy"] = {"extension_pages": policy}
    files = {
        "sw.js": "// nothing to do\n",
        "page.html": '<!doctype html><title>page</title><script src="page.js"></script>'
                     '<script>window.own.html = "ran"</script>'
                     + ('<iframe src="sb.html"></iframe>' if sandbox else ''),
        "page.js": PAGE_JS,
    }
    if sandbox:
        manifest["sandbox"] = {"pages": ["sb.html"]}
        files["sb.html"] = '<!doctype html><title>sandbox</title><script src="sb.js"></script>'
        files["sb.js"] = SANDBOX_JS
    files["manifest.json"] = json.dumps(manifest)
    return files


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


def install(name, policy=None, sandbox=False):
    folder = work / name
    folder.mkdir()
    for file, body in package(name, policy, sandbox).items():
        (folder / file).write_text(body)
    sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
    return wait_for(name)


def tried(ext, sandbox=False, within=15):
    """What its page ran and was refused, and what its sandbox frame said."""
    page = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "page.html"})["id"]
    end = time.time() + within
    own, got = {}, []
    while time.time() < end:
        try:
            own = json.loads(sv.ev(page, "JSON.stringify(window.own || {})") or "{}")
            got = json.loads(sv.ev(page, "JSON.stringify(window.got || [])") or "[]")
            if "wasm" in own and "storage" in own and (got or not sandbox):
                break
        except (RuntimeError, ValueError):
            pass
        time.sleep(0.25)
    time.sleep(1)  # an inline script that runs late, too
    own = json.loads(sv.ev(page, "JSON.stringify(window.own || {})") or "{}")
    sv.cmd({"do": "close", "id": page})
    return own, got


def main():
    t = sv.T()
    sv.APP = probe_copy()
    try:
        sv.setup()
        sv.launch()
        for name, policy, sandbox in (("NoScriptSrc", "object-src 'self'", False),
                                      ("NoScriptSrcSandbox", "object-src 'self'", True),
                                      ("OnlyImages", "img-src 'self' data:", False)):
            ext = install(name, policy, sandbox)
            t.ok(f"{name}: an extension whose pages' policy names no script-src loads", ext is not None)
            if not ext:
                continue
            own, got = tried(ext, sandbox)
            print(f"       {name}: its page {own}, its sandbox frame {got}")
            t.ok("… its page runs its own scripts and reaches its APIs and storage",
                 own.get("ran") and own.get("id") and own.get("storage") == "v", own)
            t.ok("… and refuses eval and new Function", own.get("eval") == "refused" and own.get("fn") == "refused", own)
            t.ok("… and inline script", "inline" not in own and "html" not in own, own)
            t.ok("… and still runs WebAssembly", own.get("wasm") == "ran", own)
            if sandbox:
                t.ok("… and its sandbox page still evals, apart",
                     len(got) == 1 and got[0].get("eval") == 42 and got[0].get("sender") == "null", got)

        for name, policy in (("WebKitDefault", None), ("ChromeUsual", "script-src 'self' 'wasm-unsafe-eval'; object-src 'self'")):
            ext = install(name, policy)
            t.ok(f"{name}: a usual Manifest V3 extension loads", ext is not None)
            if not ext:
                continue
            own, _ = tried(ext)
            print(f"       {name}: its page {own}")
            t.ok("… its page runs and reaches its APIs and storage", own.get("ran") and own.get("id") and own.get("storage") == "v", own)
            t.ok("… and refuses eval and inline script, as before",
                 own.get("eval") == "refused" and "inline" not in own and "html" not in own, own)
            if policy:
                t.ok("… and runs WebAssembly, as it asks", own.get("wasm") == "ran", own)
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
