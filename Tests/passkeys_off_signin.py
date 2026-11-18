#!/usr/bin/env python3
"""A sign-in that asks about passkeys before the password goes on to the
password with passkeys off, in a hidden probe.

Build first (`./build.sh debug`), then `python3 Tests/passkeys_off_signin.py`.
It runs in a world of its own with split_view.py's harness: started hidden,
everything removed afterwards. No account, no real passkey: the site is a
stand-in on 127.0.0.1.

X's sign-in (Nov 2026) asks, after the name, whether the browser does
passkeys: `'PublicKeyCredential' in window && 'isUserVerifyingPlatform
AuthenticatorAvailable' in window.PublicKeyCredential`. With Settings ›
Passwords › Offer passkeys off, Search had the name still on the window and
its value undefined, so that test threw a TypeError, the step never ended,
and you couldn't sign in until you turned passkeys on.

The stand-in does what X does: a request for an identity and a check for
passkeys under the field at load, then after Next the same check, and a
passkey request whose refusal sends it on to the password. Checked, with
passkeys off: the passkey object is there and says there are none here
(isConditionalMediationAvailable and isUserVerifyingPlatformAuthenticator
Available false), a passkey request and a passkey made are refused at once
with NotAllowedError, under the field included, the identity and password
requests are WebKit's own, nothing throws, and Next reaches the password.
With passkeys on: the same page reaches its passkey (a test run's made-up
one) and nothing throws.
"""
import json
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("passkeys-off-signin")

LOGIN = r"""<!doctype html><html><head><title>sign in</title></head><body>
<form id=f onsubmit="return false">
  <input id=u name=username autocomplete="username webauthn">
  <button id=next type=button>Next</button>
</form>
<div id=step>name</div>
<script>
var log = window.__log = { errors: [], at: {}, step: 'name' };
addEventListener('error', function (e) { log.errors.push(String(e.message)); });
addEventListener('unhandledrejection', function (e) { log.errors.push('unhandled ' + (e.reason && e.reason.name) + ': ' + (e.reason && e.reason.message)); });
function settle(name, make) {
  var started = Date.now();
  var timer = setTimeout(function () { log.at[name] = 'still waiting'; }, 3000);
  try {
    Promise.resolve(make()).then(function (v) { clearTimeout(timer); log.at[name] = ['resolved', v === null ? null : typeof v === 'object' ? 'object' : v, Date.now() - started]; },
                                 function (e) { clearTimeout(timer); log.at[name] = ['rejected', e && e.name, Date.now() - started]; });
  } catch (e) { clearTimeout(timer); log.at[name] = ['threw', e.name + ': ' + e.message]; }
}
// X's own checks, word for word.
function supported() { return 'PublicKeyCredential' in window && 'isUserVerifyingPlatformAuthenticatorAvailable' in window.PublicKeyCredential; }
function constructor() { return window.PublicKeyCredential ?? null; }
log.shape = { inWindow: 'PublicKeyCredential' in window, type: typeof window.PublicKeyCredential,
              credentials: typeof navigator.credentials };
try { log.shape.supported = supported(); } catch (e) { log.shape.supported = 'threw ' + e.name; }
var bytes = function () { return new Uint8Array(16); };
// Under the field at load: an identity request, then the passkey one if the browser has them.
settle('identity', function () { return navigator.credentials.get({ identity: { providers: [{ configURL: 'https://idp.invalid/config.json', clientId: 'x' }] } }); });
settle('password', function () { return navigator.credentials.get({ password: true }); });
settle('uvpa', function () { return PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable(); });
settle('caps', function () { var P = constructor(); return P && P.getClientCapabilities ? P.getClientCapabilities().then(function (c) { return JSON.stringify(c); }) : 'none'; });
settle('cma', function () {
  return PublicKeyCredential.isConditionalMediationAvailable().then(function (ok) {
    if (ok) settle('conditional', function () { return navigator.credentials.get({ mediation: 'conditional', publicKey: { challenge: bytes(), rpId: location.hostname } }); });
    return ok;
  });
});
// Asked of the browser anyway, as some sites do without looking first.
settle('conditionalAnyway', function () { return navigator.credentials.get({ mediation: 'conditional', publicKey: { challenge: bytes(), rpId: location.hostname } }); });
settle('createAnyway', function () { return navigator.credentials.create({ publicKey: { challenge: bytes(), rp: { name: 'stand-in' },
  user: { id: bytes(), name: 'nobody', displayName: 'nobody' }, pubKeyCredParams: [{ type: 'public-key', alg: -7 }] } }); });
// Next: X's passkey step. Not supported: skip it. A refusal: on to the password.
document.getElementById('next').addEventListener('click', function () {
  var go = function (step) { log.step = step; document.getElementById('step').textContent = step; };
  go('passkey?');
  Promise.resolve().then(function () {
    if (!supported()) return go('password');
    return navigator.credentials.get({ publicKey: { challenge: bytes(), rpId: location.hostname, userVerification: 'preferred' } })
      .then(function (c) { go(c ? 'signed in with a passkey' : 'password'); },
            function (e) { go(e && e.name === 'NotAllowedError' ? 'password' : 'failed: ' + (e && e.name)); });
  }).catch(function (e) { log.errors.push('next ' + e.name + ': ' + e.message); });
});
</script></body></html>"""


class Site(BaseHTTPRequestHandler):
    def do_GET(self):
        body = LOGIN.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def until(tid, js, within):
    end = time.time() + within
    value = None
    while time.time() < end:
        try: value = sv.ev(tid, js)
        except RuntimeError: value = None
        if value:
            return value
        time.sleep(0.25)
    return value


def run(t, port, offered):
    label = "on" if offered else "off"
    # A debug build has no entitlement: "passkeys.for" false keeps the switch
    # as set here rather than reset for the kind of build.
    sv.setup(**{"passkeys": offered, "passkeys.for": False, "passkeys.entitled": False})
    sv.launch()
    try:
        tid = sv.cmd({"do": "open", "url": f"http://127.0.0.1:{port}/login"})["id"]
        until(tid, "window.__log && Object.keys(__log.at).length >= 7 ? 'yes' : ''", 10)
        time.sleep(3.5)
        log = json.loads(sv.ev(tid, "JSON.stringify(window.__log)"))
        shape, at = log["shape"], log["at"]
        t.ok(f"{label}: the passkey object is there", shape["inWindow"] and shape["type"] == "function", shape)
        t.ok(f"{label}: X's check for passkeys answers without throwing", shape["supported"] is True, shape)
        t.ok(f"{label}: the identity request is WebKit's own", at.get("identity", [None])[0] == "rejected"
             and at["identity"][1] == "NotSupportedError", at.get("identity"))
        t.ok(f"{label}: the password request is WebKit's own", at.get("password", [None])[0] in ("rejected", "resolved"), at.get("password"))
        if not offered:
            t.ok("off: isConditionalMediationAvailable() is false", at.get("cma") and at["cma"][:2] == ["resolved", False], at.get("cma"))
            t.ok("off: isUserVerifyingPlatformAuthenticatorAvailable() is false", at.get("uvpa") and at["uvpa"][:2] == ["resolved", False], at.get("uvpa"))
            caps = json.loads(at["caps"][1]) if at.get("caps", [None])[0] == "resolved" and at["caps"][1] not in ("none",) else {}
            t.ok("off: getClientCapabilities() offers no passkeys", not any(caps.get(k) for k in
                 ("conditionalGet", "conditionalCreate", "passkeyPlatformAuthenticator", "userVerifyingPlatformAuthenticator", "hybridTransport")), at.get("caps"))
            t.ok("off: no request under the field is made", "conditional" not in at, at)
            for name in ("conditionalAnyway", "createAnyway"):
                got = at.get(name)
                t.ok(f"off: {name}: refused at once with NotAllowedError", got and got[:2] == ["rejected", "NotAllowedError"] and got[2] < 1000, got)
        else:
            t.ok("on: isConditionalMediationAvailable() answers", at.get("cma", [None])[0] == "resolved", at.get("cma"))
        sv.cmd({"do": "click", "id": tid, "selector": "#next"})
        want = "signed in with a passkey" if offered else "password"
        step = until(tid, f"__log.step === {json.dumps(want)} ? __log.step : ''", 8) or sv.ev(tid, "__log.step")
        t.ok(f"{label}: Next goes on to {'the passkey' if offered else 'the password'}", step == want, step)
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
