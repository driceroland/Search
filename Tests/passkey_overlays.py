#!/usr/bin/env python3
"""Passkeys in Peek and Little windows use their committed page (#1263).

Build first (`./build.sh debug`), then `python3 Tests/passkey_overlays.py`.
The split harness starts a hidden, isolated probe. The real page bridge and
origin checks run, but credentials are synthetic: no account or Touch ID.
"""
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("passkey-overlays")
results = {}


class Site(BaseHTTPRequestHandler):
    def do_GET(self):
        query = parse_qs(urlparse(self.path).query)
        if self.path.startswith("/result"):
            results[query["case"][0]] = query["value"][0]
            body = b"ok"
        elif self.path.startswith("/page?"):
            case = query["case"][0]
            next_url = query.get("next", [None])[0]
            script = """
setTimeout(async function () {
    let value;
    try {
        const credential = await navigator.credentials.get({publicKey: {
            challenge: new Uint8Array(32), rpId: location.hostname, timeout: 5000
        }});
        value = credential.type;
    } catch (error) { value = error.name + ': ' + error.message; }
    await fetch('/result?case=' + encodeURIComponent(CASE) + '&value=' + encodeURIComponent(value));
    if (NEXT) location.href = NEXT;
}, 100);
""".replace("CASE", json.dumps(case)).replace("NEXT", json.dumps(next_url))
            body = ("<!doctype html><title>Passkey probe</title><script>" + script + "</script>").encode()
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Site)
threading.Thread(target=server.serve_forever, daemon=True).start()
port = server.server_port


def page(case, host="localhost", next_case=None):
    from urllib.parse import urlencode
    query = {"case": case}
    if next_case:
        query["next"] = page(next_case, "127.0.0.1")
    return f"http://{host}:{port}/page?{urlencode(query)}"


def check(t, case):
    deadline = time.monotonic() + 10
    while case not in results and time.monotonic() < deadline:
        time.sleep(0.05)
    t.ok(case + ": the page receives a passkey", results.get(case) == "public-key", results.get(case, "no result"))


def main():
    t = sv.T()
    try:
        sv.setup(**{"passkeys": True, "passkeys.for": False, "passkeys.entitled": False})
        sv.launch()
        sv.sp("open", url=page("normal tab"))
        check(t, "normal tab")

        sv.cmd({"do": "peek", "url": page("Peek", next_case="Peek after cross-origin navigation")})
        check(t, "Peek")
        check(t, "Peek after cross-origin navigation")
        sv.cmd({"do": "peek", "url": "close"})

        sv.cmd({"do": "little", "what": page("Little window", next_case="Little after cross-origin navigation")})
        check(t, "Little window")
        check(t, "Little after cross-origin navigation")
    finally:
        sv.finish()
        server.shutdown()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
