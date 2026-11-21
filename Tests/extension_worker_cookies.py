#!/usr/bin/env python3
"""A plain fetch from an extension's worker to a site it has been granted
carries the site's cookies, as in Chrome. In a hidden probe.

Build first (`./build.sh`), then `python3 Tests/extension_worker_cookies.py`.
It runs a copy of build/Search.app under a bundle id of its own, hidden, in
a world of its own with split_view.py's harness; the copy, its WebKit
folders and the world are removed afterwards.

Brandsearch's panel asks its worker for everything it shows. The worker
fetches app.brandsearch.co/api/user with the extension's token in
Authorization and nothing said about credentials. Chrome counts a host the
extension has been granted as the extension's own origin, so the site's
session cookie goes with that fetch, and the site's gate lets it in on the
cookie: the token alone is sent to the sign-in page. WebKit sends no cookie
across origins, and the shim handed only a page's plain fetch to
ExtensionFetch, not a worker's. So the worker got the sign-in page, 200 and
HTML, the panel read it as the account, threw, and stayed grey.

The stand-in site is http://shop.test, a name only this script's proxy
knows (as in proxy_live.py): localhost wouldn't do, a worker's fetch there
already goes through ExtensionFetch. Its /api answers JSON to a request
with the session cookie and sends any other to its sign-in page. What is
checked:

- signed out, the worker's fetch gets the sign-in page (the control);
- signed in from a tab, the worker's plain fetch gets the account: the
  cookie went, and its Authorization header with it;
- a POST arrives once, with its body and the cookie;
- what the site sets in its answer reaches the tabs;
- credentials "omit" still sends no cookie;
- a site the extension hasn't been granted gets none, and neither does a
  web page's fetch from another site;
- `extensions.credentialedFetch` off stops it.
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

sv.use("ext-worker-cookies")
BUNDLE = "com.officecommun.search.extworkercookies"
work = Path(tempfile.mkdtemp(prefix="search-extworkercookies-"))
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
        "manifest_version": 3, "name": "Worker Cookies", "version": "1.0",
        "background": {"service_worker": "sw.js"},
        "host_permissions": ["http://shop.test/*"],
    }),
    # As Brandsearch's worker fetches for its panel.
    "sw.js": """
chrome.runtime.onMessage.addListener((m, sender, reply) => {
  (async () => {
    try {
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


def worker(tid, url, init=None):
    return run(tid, f"chrome.runtime.sendMessage({json.dumps({'url': url, 'init': init or {}})})")


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
    shop, other = f"http://shop.test:{port}", f"http://other.test:{port}"
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
            ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == "Worker Cookies" and x["loaded"]), None)
            if ext: break
            time.sleep(0.25)
        t.ok("the extension loads", ext is not None)
        if not ext: return t
        tid = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "page.html"})["id"]
        time.sleep(1.5)

        r = worker(tid, f"{shop}/api/user", {"headers": bearer})
        t.ok("signed out, the worker's fetch gets the sign-in page",
             isinstance(r, dict) and r.get("status") == 200 and "Welcome back" in r.get("text", ""), r)

        tab = opened(f"{shop}/login", "signed in")
        t.ok("signing in from a tab", "session=1" in (sv.ev(opened(f"{shop}/whoami", "session"), "document.title") or ""), tab)

        r = worker(tid, f"{shop}/api/user?plain", {"headers": bearer})
        got = asked("/api/user?plain")
        t.ok("signed in, the worker's plain fetch gets the account", account(r), r)
        t.ok("the session cookie went with it, and its Authorization header",
             len(got) == 1 and "session=1" in got[0]["cookie"] and got[0]["authorization"] == bearer["Authorization"], got)

        body = json.dumps({"brand": "example.com"})
        r = worker(tid, f"{shop}/api/save", {"method": "POST", "headers": bearer, "body": body})
        got = asked("/api/save")
        t.ok("its POST arrives once, with its body and the cookie",
             account(r) and len(got) == 1 and got[0]["body"] == body and "session=1" in got[0]["cookie"], (r, got))

        r = worker(tid, f"{shop}/api/renew", {"headers": bearer})
        title = sv.ev(opened(f"{shop}/whoami?after", "renewed"), "document.title") or ""
        t.ok("what the site sets in its answer reaches the tabs", "renewed=1" in title and "session=1" in title, (r, title))

        r = worker(tid, f"{shop}/api/user?omit", {"headers": bearer, "credentials": "omit"})
        got = asked("/api/user?omit")
        t.ok('credentials "omit" still sends no cookie', not account(r) and all(not g["cookie"] for g in got), (r, got))

        opened(f"{other}/login", "signed in")
        r = worker(tid, f"{other}/api/user?other", {"headers": bearer})
        got = asked("/api/user?other", host="other.test")
        t.ok("a site the extension hasn't been granted gets no cookie", not account(r) and all(not g["cookie"] for g in got), (r, got))

        page = sv.page("site")
        run(page, f"fetch('{shop}/api/user?page', {{mode: 'no-cors'}}).then(() => 1, () => 0)")
        time.sleep(0.5)
        got = asked("/api/user?page")
        t.ok("nor does a web page's fetch from another site", all(not g["cookie"] for g in got), got)

        subprocess.run(["defaults", "write", sv.SUITE, "extensions.credentialedFetch", "-bool", "false"], check=True)
        time.sleep(0.5)
        r = worker(tid, f"{shop}/api/user?off", {"headers": bearer})
        got = asked("/api/user?off")
        t.ok("extensions.credentialedFetch off stops it", not account(r) and all(not g["cookie"] for g in got), (r, got))
    finally:
        sv.finish()
        site.shutdown()
        proxy.shutdown()
        forget()
        subprocess.run(["defaults", "delete", sv.SUITE, "network.proxy"], capture_output=True)
        subprocess.run(["defaults", "delete", sv.SUITE, "extensions.credentialedFetch"], capture_output=True)
        shutil.rmtree(work, ignore_errors=True)
    return t


if __name__ == "__main__":
    t = main()
    t.done()
    sys.exit(1 if t.failed else 0)
