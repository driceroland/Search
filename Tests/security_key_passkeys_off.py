#!/usr/bin/env python3
"""A security key still works with Settings › Passwords › Offer passkeys off,
in a hidden probe.

Build first (`./build.sh debug`), then `python3 Tests/security_key_passkeys_off.py`.
It runs in a world of its own with split_view.py's harness: started hidden,
everything removed afterwards. No account, no key, no real passkey: the site
is a stand-in on 127.0.0.1, and a test run's ceremony is made up on the spot
(see Passkeys.rehearsal), so what is checked is which requests get through
and what they are offered.

From 1.0.15 on, with passkeys off, every request for a public key was
refused at once, so a YubiKey as a second step after the password failed
with "The operation either timed out or was not allowed." before any sheet.

Checked, with passkeys off: a sign-in naming a key over USB, NFC or
Bluetooth, and a key made with authenticatorAttachment "cross-platform",
reach Search's side and are offered the security key alone; a sign-in naming
no key, or only a passkey ("internal", "hybrid"), one from under the name
field, and a passkey made for the Mac are still refused at once; the page is
still told there are no passkeys here; and a request a page hands Search's
side itself, past the patch, is refused there too. With passkeys on, the
same sign-in is offered both the Mac's passkeys and the key, as before.
"""
import json
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("security-key-off")

PAGE = r"""<!doctype html><html><head><title>key</title></head><body>
<script>
var log = window.__log = { at: {}, errors: [] };
addEventListener('error', function (e) { log.errors.push(String(e.message)); });
var bytes = function () { return new Uint8Array(16); };
function key(transports) { return [{ type: 'public-key', id: new Uint8Array([1, 2, 3, 4]), transports: transports }]; }
function settle(name, make) {
  var started = Date.now();
  try {
    Promise.resolve(make()).then(function (c) {
      log.at[name] = ['resolved', c && c.authenticatorAttachment,
                      c && c.response && c.response.getTransports ? c.response.getTransports() : null, Date.now() - started];
    }, function (e) { log.at[name] = ['rejected', e && e.name, null, Date.now() - started]; });
  } catch (e) { log.at[name] = ['threw', e.name]; }
}
window.__run = function (names) {
  var all = {
    usb: function () { return navigator.credentials.get({ publicKey: { challenge: bytes(), allowCredentials: key(['usb']) } }); },
    nfc: function () { return navigator.credentials.get({ publicKey: { challenge: bytes(), allowCredentials: key(['nfc', 'usb']) } }); },
    internal: function () { return navigator.credentials.get({ publicKey: { challenge: bytes(), allowCredentials: key(['internal', 'hybrid']) } }); },
    unnamed: function () { return navigator.credentials.get({ publicKey: { challenge: bytes(), allowCredentials: key([]) } }); },
    none: function () { return navigator.credentials.get({ publicKey: { challenge: bytes() } }); },
    underField: function () { return navigator.credentials.get({ mediation: 'conditional', publicKey: { challenge: bytes(), allowCredentials: key(['usb']) } }); },
    makeKey: function () { return navigator.credentials.create({ publicKey: { challenge: bytes(), rp: { name: 'stand-in' },
      user: { id: bytes(), name: 'nobody', displayName: 'nobody' }, pubKeyCredParams: [{ type: 'public-key', alg: -7 }],
      authenticatorSelection: { authenticatorAttachment: 'cross-platform' } } }); },
    makePasskey: function () { return navigator.credentials.create({ publicKey: { challenge: bytes(), rp: { name: 'stand-in' },
      user: { id: bytes(), name: 'nobody', displayName: 'nobody' }, pubKeyCredParams: [{ type: 'public-key', alg: -7 }],
      authenticatorSelection: { authenticatorAttachment: 'platform' } } }); },
    makeAny: function () { return navigator.credentials.create({ publicKey: { challenge: bytes(), rp: { name: 'stand-in' },
      user: { id: bytes(), name: 'nobody', displayName: 'nobody' }, pubKeyCredParams: [{ type: 'public-key', alg: -7 }] } }); },
    // Past the patch: straight to Search's side, as any page can.
    direct: function () {
      return new Promise(function (resolve, reject) {
        var token = 'direct' + Math.random();
        addEventListener('search-passkeys-answer', function (e) {
          var data = JSON.parse(e.detail);
          if (data.token !== token) return;
          if (data.reply && data.reply.error) reject(new DOMException('', data.reply.error)); else resolve(data.reply);
        });
        dispatchEvent(new CustomEvent('search-passkeys-ask', { detail: JSON.stringify({ kind: 'get', token: token, challenge: 'AAAA', allowCredentials: [] }) }));
      });
    }
  };
  names.forEach(function (n) { settle(n, all[n]); });
};
</script></body></html>"""


class Site(BaseHTTPRequestHandler):
    def do_GET(self):
        body = PAGE.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def until(fn, within):
    end = time.time() + within
    value = None
    while time.time() < end:
        try: value = fn()
        except RuntimeError: value = None
        if value:
            return value
        time.sleep(0.25)
    return value


def one(tid, name):
    """Runs one request alone, and what Search's side saw of it."""
    before = sv.cmd({"do": "probe"}).get("passkeyAsks", 0)
    sv.ev(tid, f"__run([{json.dumps(name)}]), 'ok'")
    got = until(lambda: json.loads(sv.ev(tid, f"JSON.stringify(__log.at[{json.dumps(name)}] || null)")), 5)
    probe = sv.cmd({"do": "probe"})
    reached = probe.get("passkeyAsks", 0) - before
    return got, reached, (probe.get("passkeyLast") or {}) if reached else {}


def run(t, port, offered):
    label = "on" if offered else "off"
    sv.setup(**{"passkeys": offered, "passkeys.for": False, "passkeys.entitled": False})
    sv.launch()
    try:
        tid = sv.cmd({"do": "open", "url": f"http://127.0.0.1:{port}/key"})["id"]
        until(lambda: sv.ev(tid, "typeof __run === 'function' ? 'yes' : ''"), 10)
        if not offered:
            sv.ev(tid, "Promise.all([PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable(),"
                       " PublicKeyCredential.isConditionalMediationAvailable()]).then(function (v) { window.__told = v; }), 'ok'")
            told = until(lambda: sv.ev(tid, "window.__told ? JSON.stringify(window.__told) : ''"), 3)
            t.ok("off: the page is still told there are no passkeys here", told == "[false,false]", told)
            for name in ("usb", "nfc"):
                got, reached, last = one(tid, name)
                t.ok(f"off: a sign-in naming a key ({name}) gets its key", got and got[:2] == ["resolved", "cross-platform"], got)
                t.ok(f"off: …offered the security key alone", reached == 1 and last.get("keysOnly") is True and last.get("requests") == 1, last)
            got, reached, last = one(tid, "makeKey")
            t.ok("off: a key made cross-platform is made", got and got[:3] == ["resolved", "cross-platform", ["usb"]], got)
            t.ok("off: …offered the security key alone", reached == 1 and last.get("keysOnly") is True and last.get("requests") == 1, last)
            for name in ("internal", "unnamed", "none", "underField", "makePasskey", "makeAny"):
                got, reached, _ = one(tid, name)
                t.ok(f"off: {name}: refused at once with NotAllowedError", got and got[:2] == ["rejected", "NotAllowedError"]
                     and got[3] < 1000 and reached == 0, (got, reached))
            got, reached, _ = one(tid, "direct")
            t.ok("off: a passkey request handed to Search's side directly is refused there",
                 got and got[:2] == ["rejected", "NotAllowedError"] and reached == 0, (got, reached))
        else:
            got, reached, last = one(tid, "usb")
            t.ok("on: a sign-in naming a key is offered the Mac's passkeys and the key", got and got[0] == "resolved"
                 and reached == 1 and last.get("keysOnly") is False and last.get("requests") == 2, (got, last))
        errors = json.loads(sv.ev(tid, "JSON.stringify(__log.errors)"))
        t.ok(f"{label}: nothing on the page throws", not errors, errors)
    finally:
        sv.finish()


def main():
    t = sv.T()
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Site)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    run(t, srv.server_port, offered=False)
    run(t, srv.server_port, offered=True)
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
