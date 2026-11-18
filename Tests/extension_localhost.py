#!/usr/bin/env python3
"""An extension's worker reaches an app on this Mac it names in its manifest,
in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/extension_localhost.py`. It
runs a copy of build/Search.app under a bundle id of its own, in a world of
its own with split_view.py's harness, started hidden; the copy, its WebKit
folders and the world are removed afterwards.

Eagle's extension saves an image by asking the Eagle app's local server
(http://localhost:41595) from its worker, as 好采助手 does; Chrome lets an
extension fetch a host it declares without CORS headers, and that server
sends none. WebKit holds a worker's fetch to CORS anyway: the request
reached the app and the worker was told "Load failed", so nothing was ever
saved. Here a pretend app that sends no CORS headers stands in.

Two more things stood in the way. 好采助手 names the app with its port
("http://localhost:41595/*"), a pattern WebKit can't parse and drops, so it
was granted nothing there. And Eagle's worker never got as far as asking:
it tells its background from its pages by `getBackgroundPage() === window`,
which Chrome's worker doesn't have and WebKit's does, so it read `window`,
threw, and half its scripts never loaded. What is checked:

- the worker can do Eagle's `getBackgroundPage() === window` without
  throwing, and `typeof window` is still "undefined";

- the worker's GET and POST to the address it declares come back readable,
  and the POST arrives with its body;
- a loopback port it doesn't declare stays unreadable;
- a web page gets nothing more: its fetch to that app still fails.

With SEARCH_EAGLE=1 it also installs the real Eagle extension from the Web
Store and has its worker ask a pretend Eagle on 127.0.0.1:41595 (skipped if
that port is taken, e.g. by the Eagle app).
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("ext-localhost")
BUNDLE = "com.officecommun.search.extlocalhost"
EAGLE = "lieogkinebikhdchceieedcigeafdkid"
work = Path(tempfile.mkdtemp(prefix="search-extlocalhost-"))


class App(BaseHTTPRequestHandler):
    """An app's local server, as Eagle's answers: JSON, no CORS headers."""
    protocol_version = "HTTP/1.1"
    seen = []

    def answer(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def note(self, body=b""):
        App.seen.append({"port": self.server.server_port, "method": self.command, "path": self.path,
                         "origin": self.headers.get("Origin"), "body": body.decode("utf-8", "replace")})

    def do_OPTIONS(self):
        self.note()
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        self.note()
        if self.path in ("/", "/api/application/info"):
            self.answer({"status": "success", "data": {"version": "4.0.0", "buildVersion": "100", "platform": "darwin", "preferences": {}}})
        else:
            self.answer({"status": "success", "data": []})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        self.note(self.rfile.read(n) if n else b"")
        self.answer({"status": "success", "data": {}})

    def log_message(self, *a):
        pass


def serve(port=0):
    server = ThreadingHTTPServer(("127.0.0.1", port), App)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def free(port):
    with socket.socket() as s:
        return s.connect_ex(("127.0.0.1", port)) != 0


def extension(port):
    return {
        "manifest.json": json.dumps({
            "manifest_version": 3, "name": "Loopback", "version": "1.0",
            "background": {"service_worker": "sw.js"},
            "host_permissions": [f"http://localhost:{port}/*"],
        }),
        "sw.js": """
chrome.runtime.onMessage.addListener((m, sender, reply) => {
  if (m.background) {
    // Eagle's way of telling its background from its pages.
    let threw = null;
    try { void (chrome.extension.getBackgroundPage && chrome.extension.getBackgroundPage() === window); } catch (e) { threw = String(e); }
    reply({ threw, typeofWindow: typeof window, selfWindow: self.window === undefined });
    return;
  }
  (async () => {
    try {
      const r = await fetch(m.url, m.init || {});
      reply({ status: r.status, text: (await r.text()).slice(0, 300) });
    } catch (e) { reply({ error: String(e) }); }
  })();
  return true;
});
""",
        "page.html": "<!doctype html><p>page</p>",
    }


def probe_copy():
    """build/Search.app under a bundle id of its own, signed ad hoc."""
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


def worker(tid, url, init=None):
    return run(tid, f"chrome.runtime.sendMessage({json.dumps({'url': url, 'init': init or {}})})")


def loaded(match, within=60):
    end = time.time() + within
    while time.time() < end:
        ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if match(x) and x["loaded"]), None)
        if ext:
            return ext
        time.sleep(0.5)
    return None


def main():
    t = sv.T()
    app, other = serve(), serve()
    port, undeclared = app.server_port, other.server_port
    folder = work / "ext"
    folder.mkdir()
    for name, body in extension(port).items():
        (folder / name).write_text(body)
    sv.APP = probe_copy()
    try:
        sv.setup()
        sv.launch()
        sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
        ext = loaded(lambda x: x["name"] == "Loopback", 15)
        t.ok("the extension loads", ext is not None)
        if not ext:
            return t
        tid = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "page.html"})["id"]
        time.sleep(1.5)

        r = run(tid, "chrome.runtime.sendMessage({background: true})")
        t.ok("the worker can compare getBackgroundPage() with window without throwing, window still undefined",
             r == {"threw": None, "typeofWindow": "undefined", "selfWindow": True}, r)

        info = f"http://localhost:{port}/api/application/info"
        r = worker(tid, info)
        t.ok("the worker's GET to the app it declares comes back readable",
             isinstance(r, dict) and r.get("status") == 200 and '"success"' in r.get("text", ""), r)
        r = worker(tid, info, {"credentials": "omit"})
        t.ok("and so with credentials omit", isinstance(r, dict) and r.get("status") == 200, r)

        App.seen.clear()
        body = json.dumps({"url": "https://example.com/a.png", "name": "a"})
        r = worker(tid, f"http://localhost:{port}/api/item/addFromURL",
                   {"method": "POST", "headers": {"Content-Type": "application/json"}, "body": body})
        posted = [s for s in App.seen if s["method"] == "POST" and s["port"] == port]
        t.ok("the worker's POST comes back readable", isinstance(r, dict) and r.get("status") == 200, r)
        t.ok("and arrives once, with its body, from the extension's origin",
             len(posted) == 1 and posted[0]["body"] == body and (posted[0]["origin"] or "").endswith(ext["id"]), App.seen)

        r = worker(tid, f"http://localhost:{undeclared}/api/application/info")
        t.ok("a loopback port it doesn't declare stays unreadable", isinstance(r, dict) and "error" in r, r)

        site = sv.page("site")
        r = run(site, f"fetch('http://localhost:{port}/api/application/info').then(r => r.status)")
        t.ok("a web page's fetch to the app still fails", isinstance(r, dict) and "error" in r, r)

        if os.environ.get("SEARCH_EAGLE") == "1":
            if not free(41595):
                print("  skip  the real Eagle extension: 127.0.0.1:41595 is taken")
            else:
                eagle_app = serve(41595)
                try:
                    App.seen.clear()
                    sv.cmd({"do": "ext-answer", "answer": "yes"})
                    sv.cmd({"do": "ext-add", "id": EAGLE, "yes": True})
                    eagle = loaded(lambda x: x["id"] == EAGLE, 90)
                    t.ok("Eagle's extension loads", eagle is not None)
                    if eagle:
                        time.sleep(4)
                        # Its worker asks whether Eagle is open as it starts;
                        # when the answer was thrown away it reported an error.
                        reported = next(x for x in sv.cmd({"do": "extensions"})["extensions"] if x["id"] == EAGLE).get("reported", [])
                        t.ok("Eagle's worker asks the app as it starts, without an error",
                             any(s["port"] == 41595 and s["path"] == "/" for s in App.seen)
                             and not any("isEagleOpen" in line for line in reported), (App.seen, reported))
                        # A bare page of its own: its popup answers its own
                        # messages too, and first.
                        page = sv.cmd({"do": "ext-page", "id": EAGLE, "path": "manifest.json"})["id"]
                        time.sleep(1.5)
                        App.seen.clear()
                        ask = lambda url, opts: run(page, "chrome.runtime.sendMessage("
                                                    + json.dumps({"channel": "fetch", "url": url, "options": opts}) + ")")
                        r = ask("http://localhost:41595", {"timeout": 3000})
                        t.ok("Eagle's worker reads the app's answer", isinstance(r, dict) and r.get("status") == "success", r)
                        r = ask("http://localhost:41595/api/item/addFromURL",
                                {"method": "POST", "headers": {"Content-Type": "application/json"},
                                 "body": json.dumps({"url": "https://example.com/a.png", "name": "a"}), "timeout": 3000})
                        t.ok("and its save reaches the app and comes back ok",
                             isinstance(r, dict) and r.get("status") == "success"
                             and any(s["path"] == "/api/item/addFromURL" and s["method"] == "POST" for s in App.seen), r)
                finally:
                    eagle_app.shutdown()
    finally:
        sv.finish()
        app.shutdown()
        other.shutdown()
        for kind in ("WebKit", "Caches", "HTTPStorages"):
            shutil.rmtree(Path.home() / "Library" / kind / BUNDLE, ignore_errors=True)
        shutil.rmtree(work, ignore_errors=True)
    return t


if __name__ == "__main__":
    t = main()
    t.done()
    sys.exit(1 if t.failed else 0)
