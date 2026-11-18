#!/usr/bin/env python3
"""An extension's own script, refused by a page's Content Security Policy,
still runs in the page, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/extension_page_script.py`.
It runs a copy of build/Search.app under a bundle id of its own, in a world
of its own with split_view.py's harness, started hidden; the copy, its
WebKit folders and the world are removed afterwards.

In Chrome a <script src="chrome-extension://<id>/…"> that a content script
adds runs whatever the page's policy; WebKit held it to the page's, and on
YouTube, whose script-src names no extension, Language Reactor and Ambient
light never showed (idea 678). The browser now runs such a script itself
(ExtensionPageScript.swift). Served here: a page with YouTube's kind of
policy (an allowlist of hosts beside a nonce policy, and Trusted Types),
and one with none. What is checked:

- the content script's own web-accessible script runs in the page's world,
  once, with document.currentScript its element, and the element hears load;
- a file of the extension's that isn't web-accessible doesn't run, the
  element hears error, and the refusal is in the extension's error list;
- a script element the page itself adds with the extension's address isn't
  run for it;
- on a page without a policy the script loads by itself, once, as before.

With SEARCH_YOUTUBE=1 it also installs Language Reactor and Ambient light
from the Web Store and looks for them on a YouTube watch page.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("ext-page-script")
BUNDLE = "com.officecommun.search.extpagescript"
LR, AL = "hoombieeljmmljlkjmnheibnpciblicm", "paponcgjfojgemddooebbgniglhkajkj"
work = Path(tempfile.mkdtemp(prefix="search-extpagescript-"))


class Site(BaseHTTPRequestHandler):
    def do_GET(self):
        # The page keeps a currentScript of its own, which must be its again
        # once the extension's script has run; the strict page frames
        # another, whose content script is refused (top frame only).
        own = (b"<script nonce=abc>window.pageOwn = 1; window.ownCurrent = { mine: true };"
               b"Object.defineProperty(document, 'currentScript', { configurable: true, get: () => window.ownCurrent });</script>")
        frame = b"<iframe src='/strict-frame'></iframe>" if self.path == "/strict" else b""
        body = b"<!doctype html><title>t</title><p>page</p>" + own + frame
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        if self.path.startswith("/strict"):
            # YouTube's, in short.
            self.send_header("Content-Security-Policy", "script-src 'unsafe-eval' 'self' 'unsafe-inline' https://www.google.com")
            self.send_header("Content-Security-Policy", "script-src 'nonce-abc' 'unsafe-inline' 'strict-dynamic' https: http: 'unsafe-eval'")
            self.send_header("Content-Security-Policy", "require-trusted-types-for 'script'")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


FILES = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "PageScript", "version": "1.0",
        # The browser is asked through the extension's background.
        "background": {"service_worker": "sw.js"},
        "content_scripts": [{"matches": ["http://127.0.0.1/*"], "js": ["cs.js"], "run_at": "document_idle", "all_frames": True}],
        "web_accessible_resources": [{"resources": ["page.js"], "matches": ["http://127.0.0.1/*"]}],
    }),
    "sw.js": "chrome.runtime.onMessage.addListener(() => {});",
    # Counts its runs, and says what document.currentScript was and which
    # world it ran in.
    "page.js": """
document.documentElement.dataset.runs = String(Number(document.documentElement.dataset.runs || 0) + 1);
const current = document.currentScript;
document.documentElement.dataset.current = current && current.dataset ? (current.dataset.tag || "no tag") : current ? "the page's own" : "none";
document.documentElement.dataset.world = typeof window.pageOwn;
document.documentElement.dataset.active = String(navigator.userActivation.isActive) + " " + String(navigator.userActivation.hasBeenActive);
""",
    "hidden.js": "document.documentElement.dataset.hidden = 'ran';",
    "cs.js": """
const add = (file, tag) => {
  const s = document.createElement("script");
  s.src = chrome.runtime.getURL(file);
  s.dataset.tag = tag;
  s.addEventListener("load", () => { document.documentElement.dataset["load" + tag] = "load"; });
  s.addEventListener("error", () => { document.documentElement.dataset["load" + tag] = "error"; });
  (document.head || document.documentElement).appendChild(s);
};
add("page.js", "One");
add("hidden.js", "Two");
""",
}

LOOK = "JSON.stringify(Object.assign({}, document.documentElement.dataset))"


def probe_copy():
    """build/Search.app under a bundle id of its own, signed ad hoc."""
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def loaded(match, within=60):
    end = time.time() + within
    while time.time() < end:
        ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if match(x) and x["loaded"]), None)
        if ext:
            return ext
        time.sleep(0.5)
    return None


def look(tid, within=10, until=lambda d: False):
    end = time.time() + within
    found = {}
    while time.time() < end:
        found = json.loads(sv.ev(tid, LOOK) or "{}")
        if until(found):
            break
        time.sleep(0.3)
    return found


def main():
    t = sv.T()
    site = ThreadingHTTPServer(("127.0.0.1", 0), Site)
    threading.Thread(target=site.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{site.server_port}"
    folder = work / "ext"
    folder.mkdir()
    for name, body in FILES.items():
        (folder / name).write_text(body)
    sv.APP = probe_copy()
    try:
        sv.setup()
        sv.launch()
        sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
        ext = loaded(lambda x: x["name"] == "PageScript", 15)
        t.ok("the extension loads", ext is not None)
        if not ext:
            return t

        tid = sv.sp("open", url=base + "/strict")["resultID"]
        # Nothing asked of the page before its script has run: a script the
        # bench runs there counts as a user gesture itself.
        time.sleep(10)
        d = look(tid, within=15, until=lambda d: "loadOne" in d and "loadTwo" in d)
        t.ok("its web-accessible script runs in a page whose policy refuses it, once", d.get("runs") == "1", d)
        t.ok("in the page's own world", d.get("world") == "number", d)
        t.ok("with document.currentScript its element", d.get("current") == "One", d)
        strict_active = d.get("active", "")
        t.ok("without a user gesture: the page isn't active while it runs", strict_active.startswith("false "), d)
        t.ok("and the element hears load", d.get("loadOne") == "load", d)
        t.ok("a file that isn't web-accessible doesn't run, and its element hears error",
             "hidden" not in d and d.get("loadTwo") == "error", d)
        restored = sv.ev(tid, "String(document.currentScript === window.ownCurrent)")
        t.ok("the page's own currentScript is its own again afterwards", restored == "true", restored)
        framed = json.loads(sv.ev(tid, "JSON.stringify(Object.assign({}, frames[0].document.documentElement.dataset))") or "{}")
        t.ok("in a frame, its script isn't run, and the element hears error", "runs" not in framed and framed.get("loadOne") == "error", framed)
        time.sleep(1)
        reported = next(x for x in sv.cmd({"do": "extensions"})["extensions"] if x["id"] == ext["id"]).get("reported", [])
        t.ok("the refusals are in its error list", any("hidden.js" in r and "web_accessible_resources" in r for r in reported)
             and any("page.js" in r and "top frame" in r for r in reported), reported)

        # The page itself adds a script with the extension's address: the
        # policy refuses it, and nothing runs it for the page.
        sv.ev(tid, "(() => { const p = trustedTypes.createPolicy('t', { createScriptURL: (u) => u }); const s = document.createElement('script'); "
                   f"s.src = p.createScriptURL('chrome-extension://{ext['id']}/page.js'); s.dataset.tag = 'Page'; document.body.appendChild(s); }})(); 1")
        time.sleep(4)
        d = look(tid, within=1)
        t.ok("a script element the page adds itself isn't run for it", d.get("runs") == "1" and d.get("current") == "One", d)
        seen = sv.ev(tid, "String(typeof (window.webkit && webkit.messageHandlers && webkit.messageHandlers.searchPageScript))")
        t.ok("the page can't reach the browser's handler", seen == "undefined", seen)
        own_page = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "sw.js"})["id"]
        time.sleep(1)
        seen = sv.ev(own_page, "String(typeof (window.webkit && webkit.messageHandlers && webkit.messageHandlers.searchPageScript))")
        t.ok("nor can the extension's own pages", seen == "undefined", seen)

        tid = sv.sp("open", url=base + "/plain")["resultID"]
        time.sleep(10)
        d = look(tid, until=lambda d: "loadOne" in d and "loadTwo" in d)
        t.ok("on a page without a policy it loads by itself, once", d.get("runs") == "1" and d.get("loadOne") == "load", d)
        # Opened the same way, a page where the script loaded by itself:
        # running it for the page gave it no activation that one hasn't.
        t.ok("and the page run for has been no more activated than one where it loads by itself",
             strict_active == d.get("active"), (strict_active, d.get("active")))

        if os.environ.get("SEARCH_YOUTUBE") == "1":
            sv.cmd({"do": "ext-answer", "answer": "yes"})
            for id in (LR, AL):
                sv.cmd({"do": "ext-add", "id": id, "yes": True})
            t.ok("Language Reactor and Ambient light load", loaded(lambda x: x["id"] == LR, 90) is not None
                 and loaded(lambda x: x["id"] == AL, 90) is not None)
            time.sleep(2)
            tid = sv.sp("open", url="https://www.youtube.com/watch?v=jNQXAC9IVRw")["resultID"]
            time.sleep(25)
            marks = json.loads(sv.ev(tid, """JSON.stringify({
              scripts: [...document.scripts].map((s) => s.getAttribute('src') || '').filter((s) => s.startsWith('chrome-extension:')).map((s) => s.split('/').pop()),
              lr: [...document.querySelectorAll('*')].some((e) => /(^|[^a-z])(lln|lly)/i.test((typeof e.className === 'string' ? e.className : '') + ' ' + e.id)),
              al: [...document.querySelectorAll('*')].some((e) => /ambientlight/i.test((typeof e.className === 'string' ? e.className : '') + ' ' + e.id))})""") or "{}")
            reported = {id: next(x for x in sv.cmd({"do": "extensions"})["extensions"] if x["id"] == id).get("reported", []) for id in (LR, AL)}
            t.ok("Language Reactor shows on a YouTube watch page", marks.get("lr") is True, (marks, reported[LR]))
            t.ok("Ambient light shows on a YouTube watch page", marks.get("al") is True, (marks, reported[AL]))
    finally:
        sv.finish()
        site.shutdown()
        for kind in ("WebKit", "Caches", "HTTPStorages"):
            shutil.rmtree(Path.home() / "Library" / kind / BUNDLE, ignore_errors=True)
        shutil.rmtree(work, ignore_errors=True)
    return t


if __name__ == "__main__":
    t = main()
    t.done()
    sys.exit(1 if t.failed else 0)
