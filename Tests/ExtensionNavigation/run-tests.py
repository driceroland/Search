#!/usr/bin/env python3
"""Exercise real WebKit redirects against disposable local HTTPS fixtures."""
import http.server
import json
import os
import platform
from pathlib import Path
import ssl
import subprocess
import tempfile
import threading

TESTS = Path(__file__).resolve().parent
ROOT = TESTS.parent.parent
if platform.system() != "Darwin" or tuple(map(int, platform.mac_ver()[0].split(".")[:2])) < (15, 4):
    raise SystemExit("These WebKit fixtures require macOS 15.4 or later.")
SDK = os.environ.get("SEARCH_TEST_SDK") or subprocess.check_output(
    ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True
).strip()
TARGET = f"{platform.machine()}-apple-macos15.4"
CALLBACK = "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/callback.html?code=TEST-ONLY#state=TEST-ONLY"


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in ("/start", "/script", "/unlisted-start"):
            destination = "/redirect" if self.path == "/start" else CALLBACK
            if self.path == "/unlisted-start":
                destination = f"https://127.0.0.1:{self.server.server_port}/redirect"
            body = f'<title>Fixture</title><script>setTimeout(()=>location.href={json.dumps(destination)},100)</script>'
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(body.encode())
        else:
            destination = "/redirect" if self.path == "/chain" else CALLBACK
            if self.path == "/private":
                destination = CALLBACK.replace("callback.html", "private.html")
            self.send_response(302)
            self.send_header("Location", destination)
            self.end_headers()

    def log_message(self, *args):
        pass


with tempfile.TemporaryDirectory(prefix="search-extension-navigation-") as temporary:
    folder = Path(temporary)
    extension = folder / "extension"
    extension.mkdir()
    (extension / "manifest.json").write_text(json.dumps({
        "manifest_version": 3, "name": "Redirect fixture", "version": "1.0",
        "web_accessible_resources": [{"resources": ["callback.html"], "matches": ["https://127.0.0.1/*"]}],
    }))
    for page in ("callback.html", "private.html"):
        (extension / page).write_text("<title>Callback fixture</title><p>Synthetic resource</p>")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                    "-subj", "/CN=localhost", "-keyout", str(folder / "key.pem"),
                    "-out", str(folder / "cert.pem")], check=True, capture_output=True)
    policy_executable = folder / "policy-tests"
    subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", "-sdk", SDK,
                    "-target", TARGET,
                    str(ROOT / "Sources/Search/ExtensionRedirectPolicy.swift"),
                    str(TESTS / "policy-tests.swift"), "-o", str(policy_executable)], check=True)
    subprocess.run([str(policy_executable)], check=True)
    executable = folder / "navigation-tests"
    subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", "-sdk", SDK,
                    "-target", TARGET,
                    str(ROOT / "Sources/Search/ExtensionReturnNavigation.swift"),
                    str(ROOT / "Sources/Search/ExtensionRedirectPolicy.swift"),
                    str(TESTS / "navigation-tests.swift"), "-o", str(executable)], check=True)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(folder / "cert.pem", folder / "key.pem")
    server.socket = tls.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"https://127.0.0.1:{server.server_port}"
    cases = [
        ("baseline reproduces -1008", base + "/start", "baseline"),
        ("committed HTTPS document + server redirect", base + "/start", "allow"),
        ("blank tab + server redirect", base + "/redirect", "allow"),
        ("blank tab + redirect chain", base + "/chain", "allow"),
        ("HTTPS document + script navigation", base + "/script", "allow"),
        ("unlisted redirecting origin", base.replace("127.0.0.1", "localhost") + "/redirect", "deny"),
        ("unlisted document cannot borrow a redirector's permission", base.replace("127.0.0.1", "localhost") + "/unlisted-start", "deny"),
        ("non-public resource", base + "/private", "deny"),
        ("opaque source without a server redirect", CALLBACK, "deny"),
    ]
    try:
        for name, url, expected in cases:
            result = subprocess.run([str(executable), str(extension), url, expected], capture_output=True, text=True, timeout=25)
            print(name + ": " + result.stdout.strip(), flush=True)
            if result.returncode:
                print(result.stderr)
                raise SystemExit(result.returncode)
    finally:
        server.shutdown()
        server.server_close()
    print(f"{len(cases)} native WebKit cases passed. Real extension sign-in must also be checked manually.")
