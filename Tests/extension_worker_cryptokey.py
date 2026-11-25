#!/usr/bin/env python3
"""An extension's worker storing a CryptoKey in IndexedDB doesn't freeze
the extension (idea 439), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/extension_worker_cryptokey.py`.
A copy of build/Search.app under a bundle id of its own runs hidden in a
world of its own (split_view.py's harness); all of it is removed afterwards.

WebKit runs an extension's worker on its web process's main thread, and
wraps a CryptoKey for storage by asking that same thread for the sealing
key: the worker waited for ever, and every page of the extension with it
(NordPass's popup, an empty dark box). The shim refuses such a value with a
DataCloneError, as a browser that can't store keys does. Checked: the
worker answers with that error, the extension's page still runs script, and
storing plain values still works.
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

sv.use("extension-worker-cryptokey")
BUNDLE = "com.officecommun.search.cryptokey"
work = Path(tempfile.mkdtemp(prefix="search-cryptokey-"))
NAME = "KeyStore"

FILES = {
    "manifest.json": json.dumps({"manifest_version": 3, "name": NAME, "version": "1.0",
                                 "background": {"service_worker": "bg.js"}, "permissions": ["storage"]}),
    "bg.js": """
const open = () => new Promise((ok, no) => { const r = indexedDB.open("keys", 1); r.onupgradeneeded = () => r.result.createObjectStore("k"); r.onsuccess = () => ok(r.result); r.onerror = () => no(r.error); });
const put = async (value) => { const db = await open(); const t = db.transaction("k", "readwrite"); t.objectStore("k").put(value, "v");
  await new Promise((ok, no) => { t.oncomplete = ok; t.onerror = () => no(t.error); }); return "stored"; };
chrome.runtime.onMessage.addListener((m, s, reply) => {
  const go = m === "key" ? crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, false, ["encrypt"]).then(k => put({ nested: [k] }))
                         : put({ plain: [1, "two", new Uint8Array(3)] });
  go.then(reply, e => reply(e.name)); return true;
});
""",
    "page.html": "<!doctype html><title>KeyStore</title>",
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
    for name, body in FILES.items(): (folder / name).write_text(body)
    sv.APP = probe_copy()
    try:
        sv.setup(sidebar=True)
        sv.launch()
        sv.cmd({"do": "ext-answer", "answer": "yes"})
        sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
        ext = None
        for _ in range(60):
            ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == NAME and x["loaded"]), None)
            if ext: break
            time.sleep(0.5)
        t.ok("the extension loads", ext is not None)
        if not ext: return t
        tab = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "page.html"})["id"]
        time.sleep(1.5)

        def ask(what):
            sv.ev(tab, f"window.R = 'waiting'; setTimeout(() => chrome.runtime.sendMessage({json.dumps(what)}, v => {{ window.R = String(v); }}), 50); 1")
            for _ in range(20):
                time.sleep(0.5)
                try: r = sv.ev(tab, "window.R")
                except RuntimeError as e: return f"page stopped answering: {e}"
                if r != "waiting": return r
            return "waiting"
        t.ok("plain values are stored", ask("plain") == "stored")
        r = ask("key")
        t.ok("a CryptoKey is refused with a DataCloneError", r == "DataCloneError", r)
        t.ok("the page still runs script", sv.ev(tab, "document.title") == NAME)
        t.ok("and the worker still answers", ask("plain") == "stored")
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
