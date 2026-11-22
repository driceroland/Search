#!/usr/bin/env python3
"""An extension's webRequest listeners hear the extension's own fetches, as
in Chrome. In a hidden probe.

Build first (`./build.sh`), then `python3 Tests/extension_own_requests.py`.
It runs a copy of build/Search.app under a bundle id of its own, hidden, in
a world of its own with split_view.py's harness; the copy, its WebKit
folders and the world are removed afterwards.

Similarweb's panel opened and its spinner turned for good. Its worker
fetches data.similarweb.com/api/v1/identity and, in a
webRequest.onSendHeaders listener on that address with "requestHeaders" and
"extraHeaders", reads the Cookie header of its own request to keep
"mixpanelCookie" in storage: an empty object when the cookie isn't there.
The panel reads `.distinct_id` of what was kept. Chrome tells an extension
of its own requests, tab -1. WebKit tells of the requests tabs make, and a
fetch the browser sends for the extension (ExtensionFetch) nothing saw, so
the listener was never called, nothing was kept, and the panel threw.

The stand-in site is http://shop.test, a name only this script's proxy
knows (as in extension_worker_cookies.py). What is checked:

- a worker's fetch is heard by its own listeners, onBeforeSendHeaders
  before onSendHeaders, each once, as one request from no tab;
- the headers that went out are given to a listener that asked for
  "requestHeaders", the Cookie header only with "extraHeaders" too, and
  none to one that asked for neither;
- a listener that throws stops neither the others nor the fetch;
- what Similarweb does: the cookie read there is kept in storage;
- a redirect followed is heard again, as the same request;
- an address outside the listener's filter, a listener for one tab or for
  images only, and a listener taken off hear nothing.
"""
import json
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

sv.use("ext-own-requests")
BUNDLE = "com.officecommun.search.extownrequests"
work = Path(tempfile.mkdtemp(prefix="search-extownrequests-"))
NAMES = ("shop.test", "other.test")  # known to the proxy alone

seen = []  # what the site was asked: host, method, path, cookie, authorization, body
seen_lock = threading.Lock()


def asked(path, host="shop.test"):
    with seen_lock:
        return [r for r in seen if r["path"] == path and r["host"] == host]


class Site(BaseHTTPRequestHandler):
    """A site with a session: its /api is for whoever is signed in."""
    protocol_version = "HTTP/1.1"

    def send(self, code, kind, body, headers=()):
        body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        for k, v in headers: self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def handle_any(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode("utf-8", "replace") if n else ""
        cookie = self.headers.get("Cookie") or ""
        path = self.path.split("?")[0]
        with seen_lock:
            seen.append({"host": (self.headers.get("Host") or "").split(":")[0], "method": self.command, "path": self.path,
                         "cookie": cookie, "authorization": self.headers.get("Authorization") or "", "body": body})
        signed = "session=1" in cookie
        if path == "/login":
            self.send(200, "text/html", "<!doctype html><title>signed in</title>",
                      [("Set-Cookie", "session=1; Path=/; Max-Age=3600; SameSite=Lax")])
        elif path == "/welcome":
            self.send(200, "text/html", "<!doctype html><title>Welcome back</title><p>Sign in")
        elif path == "/whoami":
            self.send(200, "text/html", f"<!doctype html><title>{cookie or 'none'}</title>")
        elif path.startswith("/api/") and not signed:
            # The gate: no session, no API, whatever token came.
            self.send(307, "text/plain", "Redirecting...", [("Location", "/welcome")])
        elif path == "/api/hop":
            self.send(302, "text/plain", "", [("Location", "/api/user?hopped")])
        elif path == "/api/renew":
            self.send(200, "application/json", json.dumps({"renewed": True}),
                      [("Set-Cookie", "renewed=1; Path=/; Max-Age=3600; SameSite=Lax")])
        elif path.startswith("/api/"):
            self.send(200, "application/json", json.dumps({"language": "en", "body": body}))
        else:
            self.send(200, "text/html", f"<!doctype html><title>{path.strip('/')}</title>")

    do_GET = do_POST = handle_any

    def log_message(self, *a):
        pass


class Proxy(BaseHTTPRequestHandler):
    """A tunnel to wherever it is asked, NAMES being this Mac."""
    protocol_version = "HTTP/1.1"

    def do_CONNECT(self):
        host, _, port = self.path.rpartition(":")
        try:
            up = socket.create_connection(("127.0.0.1" if host in NAMES else host, int(port or 80)), timeout=5)
        except OSError:
            self.send_error(502)
            return
        self.send_response(200, "Connection established")
        self.end_headers()
        self.wfile.flush()
        down = self.connection
        upward = threading.Thread(target=self.pipe, args=(down, up), daemon=True)
        upward.start()
        self.pipe(up, down)
        upward.join(timeout=2)
        for s in (up, down):
            try: s.close()
            except OSError: pass
        self.close_connection = True

    @staticmethod
    def pipe(a, b):
        try:
            while data := a.recv(65536): b.sendall(data)
        except OSError:
            pass
        finally:
            try: b.shutdown(socket.SHUT_WR)
            except OSError: pass

    def log_message(self, *a):
        pass


def serve(handler):
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


FILES = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "Own Requests", "version": "1.0",
        "background": {"service_worker": "sw.js"},
        "permissions": ["webRequest", "storage"],
        "host_permissions": ["http://shop.test/*"],
    }),
    "sw.js": """
const heard = [];
const note = (who) => (d) => heard.push({ who, id: d.requestId, url: d.url, method: d.method, tab: d.tabId, frame: d.frameId,
  type: d.type, initiator: d.initiator,
  headers: d.requestHeaders ? Object.fromEntries(d.requestHeaders.map((h) => [h.name.toLowerCase(), h.value])) : null });
const api = { urls: ["http://shop.test/api/*"] };
chrome.webRequest.onSendHeaders.addListener(note("extra"), api, ["requestHeaders", "extraHeaders"]);
chrome.webRequest.onBeforeSendHeaders.addListener(note("before"), api, ["requestHeaders"]);
chrome.webRequest.onSendHeaders.addListener(() => { throw new Error("a listener that throws"); }, api);
chrome.webRequest.onSendHeaders.addListener(note("plain"), api, ["requestHeaders"]);
chrome.webRequest.onSendHeaders.addListener(note("bare"), api);
const gone = note("gone");
chrome.webRequest.onSendHeaders.addListener(gone, api, ["requestHeaders"]);
chrome.webRequest.onSendHeaders.removeListener(gone);
chrome.webRequest.onSendHeaders.addListener(note("one tab"), { urls: ["<all_urls>"], tabId: 5 });
chrome.webRequest.onSendHeaders.addListener(note("images"), { urls: ["<all_urls>"], types: ["image"] });
// As Similarweb's worker keeps its Mixpanel cookie.
chrome.webRequest.onSendHeaders.addListener((d) => {
  const cookie = (d.requestHeaders.find((h) => h.name === "Cookie") || {}).value || "";
  chrome.storage.local.set({ kept: { cookie } });
}, { urls: ["http://shop.test/api/identity"] }, ["requestHeaders", "extraHeaders"]);

chrome.runtime.onMessage.addListener((m, sender, reply) => {
  (async () => {
    try {
      if (m.heard) { await new Promise((r) => setTimeout(r, 300)); reply(heard.splice(0)); return; }
      if (m.kept) { reply((await chrome.storage.local.get("kept")).kept || null); return; }
      const r = await fetch(m.url, m.init || {});
      reply({ status: r.status, kind: r.headers.get("content-type") || "", url: r.url, text: (await r.text()).slice(0, 300) });
    } catch (e) { reply({ error: String(e) }); }
  })();
  return true;
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


def forget():
    """What the copy keeps outside its world, the site's cookies among it: a
    run must start signed out."""
    library = Path.home() / "Library"
    for kind in ("WebKit", "Caches", "HTTPStorages"):
        shutil.rmtree(library / kind / BUNDLE, ignore_errors=True)
    (library / "HTTPStorages" / f"{BUNDLE}.binarycookies").unlink(missing_ok=True)


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


def ask(tid, message):
    return run(tid, f"chrome.runtime.sendMessage({json.dumps(message)})")


def worker(tid, url, init=None):
    return ask(tid, {"url": url, "init": init or {}})


def heard(tid):
    r = ask(tid, {"heard": True})
    return r if isinstance(r, list) else []


def opened(url, title, within=10):
    """A tab at `url`, once it shows a title with `title` in it."""
    tid = sv.sp("open", url=url)["resultID"]
    end = time.time() + within
    while time.time() < end:
        try:
            if title in (sv.ev(tid, "document.title") or ""): return tid
        except RuntimeError:
            pass
        time.sleep(0.25)
    return tid


def account(r):
    return isinstance(r, dict) and r.get("status") == 200 and "json" in r.get("kind", "") and '"language"' in r.get("text", "")


def main():
    t = sv.T()
    site, proxy = serve(Site), serve(Proxy)
    port = site.server_port
    shop = f"http://shop.test:{port}"
    bearer = {"Authorization": "Bearer of-the-extension", "Content-Type": "application/json"}
    folder = work / "ext"
    folder.mkdir()
    for name, body in FILES.items(): (folder / name).write_text(body)
    sv.APP = probe_copy()
    try:
        sv.setup()
        forget()
        value = {"mode": "http", "host": "127.0.0.1", "port": str(proxy.server_port), "username": ""}
        subprocess.run(["defaults", "write", sv.SUITE, "network.proxy", "-data", json.dumps(value).encode().hex()], check=True)
        sv.launch()
        sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
        ext = None
        for _ in range(60):
            ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == "Own Requests" and x["loaded"]), None)
            if ext: break
            time.sleep(0.25)
        t.ok("the extension loads", ext is not None)
        if not ext: return t
        tid = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "page.html"})["id"]
        time.sleep(1.5)
        opened(f"{shop}/login", "signed in")
        heard(tid)

        r = worker(tid, f"{shop}/api/user?one", {"headers": bearer})
        h = heard(tid)
        who = [x["who"] for x in h]
        t.ok("the worker's fetch is heard by its own listeners, before sending first, each once",
             who == ["before", "extra", "plain", "bare"], h)
        t.ok("as one request, from no tab",
             bool(h) and len({x["id"] for x in h}) == 1 and all(
                 x["url"] == f"{shop}/api/user?one" and x["method"] == "GET" and x["tab"] == -1 and x["frame"] == -1
                 and x["type"] == "xmlhttprequest" and x["initiator"] == ext["base"].rstrip("/") for x in h), (h, ext["base"]))
        by = {x["who"]: x["headers"] for x in h}
        t.ok('with "extraHeaders", the headers that went out, the Cookie header among them',
             "session=1" in ((by.get("extra") or {}).get("cookie") or "")
             and (by.get("extra") or {}).get("authorization") == bearer["Authorization"], by.get("extra"))
        t.ok("without it, the headers but not the Cookie header",
             all((by.get(k) or {}).get("authorization") == bearer["Authorization"] and "cookie" not in (by.get(k) or {"cookie": 1})
                 for k in ("before", "plain")), (by.get("before"), by.get("plain")))
        t.ok('and no headers to a listener that asked for none', "bare" in by and by["bare"] is None, by.get("bare"))
        t.ok("a listener that throws doesn't stop the fetch", account(r), r)

        worker(tid, f"{shop}/api/identity", {"headers": bearer})
        time.sleep(0.5)
        kept = ask(tid, {"kept": True})
        t.ok("what Similarweb does: the cookie read from its own request is kept",
             isinstance(kept, dict) and "session=1" in kept.get("cookie", ""), kept)
        heard(tid)

        r = worker(tid, f"{shop}/api/hop", {"headers": bearer})
        h = [x for x in heard(tid) if x["who"] == "extra"]
        t.ok("a redirect followed is heard again, as the same request",
             account(r) and [x["url"] for x in h] == [f"{shop}/api/hop", f"{shop}/api/user?hopped"] and len({x["id"] for x in h}) == 1, (r, h))

        body = json.dumps({"brand": "example.com"})
        worker(tid, f"{shop}/api/save", {"method": "POST", "headers": bearer, "body": body})
        h = [x for x in heard(tid) if x["who"] == "extra"]
        got = asked("/api/save")
        t.ok("a POST is heard once and sent once", len(h) == 1 and h[0]["method"] == "POST" and len(got) == 1 and got[0]["body"] == body, (h, got))

        worker(tid, f"{shop}/whoami?outside")
        h = heard(tid)
        t.ok("an address outside the filter is not heard, nor by a listener for one tab, for images, or taken off",
             h == [] and len(asked("/whoami?outside")) == 1, h)
    finally:
        sv.finish()
        site.shutdown()
        proxy.shutdown()
        forget()
        subprocess.run(["defaults", "delete", sv.SUITE, "network.proxy"], capture_output=True)
        shutil.rmtree(work, ignore_errors=True)
    return t


if __name__ == "__main__":
    t = main()
    t.done()
    sys.exit(1 if t.failed else 0)
