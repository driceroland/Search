#!/usr/bin/env python3
"""Settings › Privacy › Proxy really carries Search's traffic, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/proxy_live.py`. It runs a copy
of build/Search.app under a bundle id of its own, hidden, in a world of its
own with split_view.py's harness; the copy, its WebKit folders and the world
are removed afterwards.

The trick: pages are asked for on the host `probe.test`, which nothing on
this Mac can resolve. Only this script's proxy knows it, and sends it to the
local page server. So a page that renders is proof it went through the proxy,
and a page that fails is proof it did not.

WebKit asks a proxy for an http:// page with CONNECT, as it does for https,
so a tunnel is all the proxy sees: the host it was opened to, and nothing of
what travels inside. That is why every check here is about a host.

Checks, in order:
  1. proxy off, probe.test is unreachable (the control: no other path exists)
  2. proxy on, the same address renders, and the proxy was asked for it
  3. Search's own fetches go through it too: the page's icon sits on a host
     of its own, so a tunnel opened to that host is the proof
  4. 127.0.0.1 still loads with the proxy on, and the proxy never saw it,
     so your own machine stays reachable
  5. the proxy off again, and probe.test is unreachable once more
"""
import json
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("proxy-live")
BUNDLE = "com.officecommun.search.proxylive"
work = Path(tempfile.mkdtemp(prefix="search-proxylive-"))

seen = []           # (method, host, port, path) the proxy was asked for
seen_lock = threading.Lock()


def note(method, host, port, path):
    with seen_lock:
        seen.append((method, host, int(port), path))


def asked(host=None, path=None):
    with seen_lock:
        return [r for r in seen
                if (host is None or r[1] == host) and (path is None or r[3] == path)]


# --- the page server: any path is a page; //favicon.ico is a real icon ------
ICON = bytes.fromhex("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4"
                     "890000000a49444154789c6300010000050001")


class Pages(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        if self.path == "/favicon.ico":
            body, kind = ICON, "image/png"
        elif self.path == "/iconned":
            body = (f"<!doctype html><title>iconned</title><link rel='icon' "
                    f"href='http://icon.test:{PAGE_PORT}/favicon.ico'><p>iconned").encode()
            kind = "text/html"
        else:
            body = f"<!doctype html><title>{self.path.strip('/')}</title><p>{self.path}".encode()
            kind = "text/html"
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


pages = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
threading.Thread(target=pages.serve_forever, daemon=True).start()
PAGE_PORT = pages.server_port


# --- the proxy: absolute-form GET and CONNECT, logging everything ----------
class Proxy(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _target(self, authority):
        host, _, port = authority.rpartition(":")
        if not host:
            host, port = authority, "80"
        # probe.test exists only here. Everything else goes where it says.
        return ("127.0.0.1" if host in ("probe.test", "icon.test") else host), int(port or 80)

    def do_GET(self):
        if not self.path.startswith("http://"):
            self.send_error(400)
            return
        rest = self.path[len("http://"):]
        authority, _, path = rest.partition("/")
        path = "/" + path
        host, port = self._target(authority)
        note("GET", authority.split(":")[0], port, path)
        try:
            with socket.create_connection((host, port), timeout=5) as up:
                head = (f"GET {path} HTTP/1.1\r\nHost: {authority}\r\n"
                        "Connection: close\r\n\r\n").encode()
                up.sendall(head)
                answer = b""
                while chunk := up.recv(65536):
                    answer += chunk
        except OSError as error:
            self.send_error(502, str(error))
            return
        self.wfile.write(answer)
        self.close_connection = True

    def do_CONNECT(self):
        host, port = self._target(self.path)
        note("CONNECT", self.path.split(":")[0], port, "")
        try:
            up = socket.create_connection((host, port), timeout=5)
        except OSError:
            self.send_error(502)
            return
        self.send_response(200, "Connection established")
        self.end_headers()
        self.wfile.flush()
        down = self.connection
        # One direction in a thread, the other right here: the handler must
        # not return while the tunnel is live, or the server closes the socket
        # under it (which is what reset the connection the first time).
        upward = threading.Thread(target=self._pipe, args=(down, up), daemon=True)
        upward.start()
        self._pipe(up, down)
        upward.join(timeout=2)
        for s in (up, down):
            try:
                s.close()
            except OSError:
                pass
        self.close_connection = True

    @staticmethod
    def _pipe(a, b):
        try:
            while data := a.recv(65536):
                b.sendall(data)
        except OSError:
            pass
        finally:
            try:
                b.shutdown(socket.SHUT_WR)
            except OSError:
                pass

    def log_message(self, *a):
        pass


proxy = ThreadingHTTPServer(("127.0.0.1", 0), Proxy)
threading.Thread(target=proxy.serve_forever, daemon=True).start()
PROXY_PORT = proxy.server_port


def probe_copy():
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}",
                    str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")),
                    "--deep", str(app)], check=True, capture_output=True)
    return str(app)


def set_proxy(on):
    """Writes the setting the way Settings would, before the app reads it."""
    if not on:
        subprocess.run(["defaults", "delete", sv.SUITE, "network.proxy"],
                       capture_output=True)
        return
    value = {"mode": "http", "host": "127.0.0.1", "port": str(PROXY_PORT), "username": ""}
    blob = json.dumps(value).encode()
    subprocess.run(["defaults", "write", sv.SUITE, "network.proxy", "-data", blob.hex()], check=True)


def title(page_id):
    if not page_id:
        return ""
    try:
        return sv.ev(page_id, "document.title") or ""
    except RuntimeError:
        return ""


def opened(url):
    # The split group's open, which is what sv.page uses and what hands back
    # the tab's id; the plain "open" verb does not.
    got = sv.sp("open", url=url)
    time.sleep(2.2)
    return got.get("resultID")


def main():
    t = sv.T()
    sv.APP = probe_copy()
    through = f"http://probe.test:{PAGE_PORT}"
    local = f"http://127.0.0.1:{PAGE_PORT}"
    try:
        # 1. The control: with no proxy, nothing can reach probe.test.
        sv.setup(sidebar=True)
        set_proxy(False)
        sv.launch()
        page = opened(f"{through}/alpha")
        t.ok("with no proxy, a host only the proxy knows is unreachable",
             "alpha" not in title(page), title(page))
        t.ok("and the proxy was never asked", not asked(host="probe.test"), seen[:3])
        sv.quit()

        # 2. The same address, with the proxy on.
        seen.clear()
        sv.setup(sidebar=True)
        set_proxy(True)
        sv.launch()
        page = opened(f"{through}/alpha")
        t.ok("with the proxy on, the page loads through it", "alpha" in title(page), title(page))
        # A CONNECT tunnel shows the host it was opened to and nothing of
        # what travels inside it, so the host is what there is to check.
        t.ok("and the proxy was asked for that host",
             bool(asked(host="probe.test")), seen[:5])

        # 3. Search's own fetches, not just pages: a favicon.
        # The icon sits on a host of its own, which nothing but the proxy can
        # reach, so a tunnel opened to it is proof Search's own fetch went
        # through the proxy rather than straight out.
        opened(f"{through}/iconned")
        got = False
        for _ in range(60):
            if asked(host="icon.test"):
                got = True
                break
            time.sleep(0.25)
        t.ok("a favicon, which Search fetches itself, goes through the proxy too",
             got, seen[-6:])

        # 4. Your own machine stays direct.
        was = len(asked(host="127.0.0.1"))
        page = opened(f"{local}/beta")
        t.ok("127.0.0.1 still loads with the proxy on", "beta" in title(page), title(page))
        t.ok("and it did not go through the proxy",
             len(asked(host="127.0.0.1")) == was,
             [r for r in seen if r[1] == "127.0.0.1"])
        sv.quit()

        # 5. Turned off again: back to unreachable.
        seen.clear()
        sv.setup(sidebar=True)
        set_proxy(False)
        sv.launch()
        page = opened(f"{through}/gamma")
        t.ok("turned off, the proxy carries nothing again",
             "gamma" not in title(page) and not asked(host="probe.test"), title(page))
    finally:
        sv.finish()
        for kind in ("WebKit", "Caches", "HTTPStorages"):
            shutil.rmtree(Path.home() / "Library" / kind / BUNDLE, ignore_errors=True)
        subprocess.run(["defaults", "delete", sv.SUITE, "network.proxy"], capture_output=True)
        shutil.rmtree(work, ignore_errors=True)
    return t


if __name__ == "__main__":
    t = main()
    t.done()
    sys.exit(1 if t.failed else 0)
