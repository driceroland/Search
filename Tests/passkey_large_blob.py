#!/usr/bin/env python3
"""The largeBlob extension reaches the page.

Build first (`./build.sh`), then `python3 Tests/passkey_large_blob.py`.
The split harness starts a hidden, isolated probe. The real page bridge and
checks run, but credentials are synthetic: no account or Touch ID.

Apple's sign-in (account.apple.com, Sign in with Apple) asks for
`largeBlob: {read: true}` on every passkey sign-in and sends the blob on to
Apple. Search used to drop the extension.
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

sv.use("passkey-large-blob")
results = {}

SCRIPT = """
async function run(name, fn) {
    let value;
    try { value = await fn(); } catch (error) { value = error.name; }
    await fetch('/result?case=' + name + '&value=' + encodeURIComponent(JSON.stringify(value === undefined ? null : value)));
}
setTimeout(async function () {
    const challenge = new Uint8Array(32);
    await run('capability', async () => (await PublicKeyCredential.getClientCapabilities())['extension:largeBlob']);
    // As Apple's widget asks, and reads it back (app-message.js).
    await run('read', async () => {
        const c = await navigator.credentials.get({publicKey: {challenge, rpId: location.hostname,
            extensions: {largeBlob: {read: true}}}});
        const r = c.getClientExtensionResults().largeBlob;
        return {binary: r.blob instanceof ArrayBuffer, text: new TextDecoder().decode(r.blob),
                json: c.toJSON().clientExtensionResults.largeBlob.blob};
    });
    await run('write', async () => {
        const c = await navigator.credentials.get({publicKey: {challenge, rpId: location.hostname,
            allowCredentials: [{type: 'public-key', id: new Uint8Array(16)}],
            extensions: {largeBlob: {write: new TextEncoder().encode('kept')}}}});
        return c.getClientExtensionResults().largeBlob;
    });
    await run('write-unnamed', async () => navigator.credentials.get({publicKey: {challenge, rpId: location.hostname,
        extensions: {largeBlob: {write: new Uint8Array(1)}}}}));
    await run('both', async () => navigator.credentials.get({publicKey: {challenge, rpId: location.hostname,
        extensions: {largeBlob: {read: true, write: new Uint8Array(1)}}}}));
    await run('create', async () => {
        const c = await navigator.credentials.create({publicKey: {challenge, rp: {name: 'probe'},
            user: {id: new Uint8Array(8), name: 'probe', displayName: 'probe'},
            pubKeyCredParams: [{type: 'public-key', alg: -7}],
            extensions: {largeBlob: {support: 'preferred'}}}});
        return c.getClientExtensionResults().largeBlob;
    });
    await run('none', async () => {
        const c = await navigator.credentials.get({publicKey: {challenge, rpId: location.hostname}});
        return 'largeBlob' in c.getClientExtensionResults();
    });
}, 100);
"""


# Apple's widget asks under the name field first: the passkey picked from the
# list there is signed in with by Passkeys.sign, apart from perform.
FIELD = """
window.__pk = 'waiting';
navigator.credentials.get({mediation: 'conditional', publicKey: {challenge: new Uint8Array(32), rpId: location.hostname,
    extensions: {largeBlob: {read: true}}}})
  .then(c => new TextDecoder().decode(c.getClientExtensionResults().largeBlob.blob), e => e.name)
  .then(v => fetch('/result?case=field&value=' + encodeURIComponent(JSON.stringify(v))));
"""


class Site(BaseHTTPRequestHandler):
    def do_GET(self):
        query = parse_qs(urlparse(self.path).query)
        if self.path.startswith("/result"):
            results[query["case"][0]] = json.loads(query["value"][0])
            body = b"ok"
        elif self.path.startswith("/field"):
            body = ('<!doctype html><title>Large blob field</title><input id="u" autocomplete="username webauthn" style="width:270px;height:40px">'
                    "<script>" + FIELD + "</script>").encode()
        elif self.path.startswith("/page"):
            body = ("<!doctype html><title>Large blob probe</title><script>" + SCRIPT + "</script>").encode()
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


def wait(case):
    deadline = time.monotonic() + 15
    while case not in results and time.monotonic() < deadline:
        time.sleep(0.05)
    return results.get(case, "no result")


def main():
    t = sv.T()
    try:
        sv.setup(**{"passkeys": True, "passkeys.for": False, "passkeys.entitled": False})
        sv.launch()
        sv.sp("open", url=f"http://localhost:{server.server_port}/page")
        t.ok("getClientCapabilities says largeBlob", wait("capability") is True, wait("capability"))
        read = wait("read")
        t.ok("read: the blob comes back as bytes", isinstance(read, dict) and read.get("binary") and read.get("text") == "rehearsal blob", read)
        t.ok("read: toJSON has it base64url", isinstance(read, dict) and read.get("json") == "cmVoZWFyc2FsIGJsb2I", read)
        t.ok("write: written", wait("write") == {"written": True}, wait("write"))
        t.ok("write without naming one passkey is refused", wait("write-unnamed") == "NotSupportedError", wait("write-unnamed"))
        t.ok("read and write at once is refused", wait("both") == "NotSupportedError", wait("both"))
        t.ok("create: supported", wait("create") == {"supported": True}, wait("create"))
        t.ok("not asked for: no largeBlob result", wait("none") is False, wait("none"))
        field = sv.sp("open", url=f"http://localhost:{server.server_port}/field")["resultID"]
        sv.sp("select", id=field)
        for _ in range(20):
            if sv.ev(field, "window.__pk") == "waiting":
                break
            time.sleep(0.25)
        sv.ev(field, "document.getElementById('u').focus(); true")
        time.sleep(1.2)  # a list younger than half a second takes no pick
        listed = sv.cmd({"do": "accounts"})
        t.ok("under the field: the passkey is offered", any("passkey" in r for r in listed.get("rows") or []), listed)
        sv.cmd({"do": "accounts", "pick": 0})
        t.ok("under the field: the blob comes back too", wait("field") == "rehearsal blob", wait("field"))
    finally:
        sv.finish()
        server.shutdown()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
