#!/usr/bin/env python3
"""A password manager's passkey reaches the page, however long you take to
pick it, in a hidden probe (idea 702).

Build first (`./build.sh`), then `python3 Tests/passkey_extension.py`. It
runs a copy of build/Search.app under a bundle id of its own, in a world of
its own with split_view.py's harness, started hidden; the copy, its WebKit
folders and the world are removed afterwards. No account, no real passkey:
the extension here stands in for one.

1Password answers a site's passkey request itself. Its script in the page's
own world takes the place of navigator.credentials.get, hands the request
to its content script, which asks its worker and waits; the worker answers
once you have picked a passkey in 1Password's menu or prompt. Chrome waits
as long as that takes. WebKit hands a content script's message to the
extension's pages in other tabs as well, and takes the first answer it
gets; Search's shim had such a page, framed in a website (1Password's menu
and prompt are), answer every message it had nothing to say about with
nothing after ten seconds. So with 1Password's menu or prompt open in
another tab, the content script heard nothing, 1Password's page script took
that for an error and asked the browser instead, and the passkey you picked
later never reached the site. It stayed on its sign-in page.

The extension here does what 1Password does, the site what sites do: a
request under the name field at load, put away (AbortController) when the
passkey button is pressed, a new one, and with the credential a POST and
a new page. With the extension's prompt framed in another tab, what is
checked:

- a message from a content script that its worker answers after 13 seconds
  gets that answer;
- a message nobody answers still gets its nothing, no later than before;
- the passkey picked 13 seconds after pressing the button is the
  extension's, reaches the server, and the tab moves on to the next page;
- the same when it is picked at once.
"""
import json
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

sv.use("passkey-extension")
BUNDLE = "com.officecommun.search.passkeyextension"
work = Path(tempfile.mkdtemp(prefix="search-passkeyextension-"))

# The site: a request under the field at load; the passkey button puts it
# away and asks again; the credential goes to the server, then a new page.
LOGIN = """<!doctype html><html><head><title>sign in</title></head><body>
<form><input id=u name=username autocomplete="username webauthn"></form>
<button id=passkey type=button>Sign in with a passkey</button>
<script>
window.__log = [];
function log(x) { __log.push(x); }
function challenge() { return crypto.getRandomValues(new Uint8Array(32)); }
var conditional = new AbortController();
PublicKeyCredential.isConditionalMediationAvailable().then(function (ok) {
  log('conditional available ' + ok);
  if (!ok) return;
  navigator.credentials.get({ mediation: 'conditional', signal: conditional.signal,
                              publicKey: { challenge: challenge(), rpId: location.hostname } })
    .then(function (c) { log('conditional answered ' + (c && c.id)); },
          function (e) { log('conditional ' + e.name); });
});
document.getElementById('passkey').onclick = function () {
  conditional.abort();
  var modal = new AbortController();
  navigator.credentials.get({ signal: modal.signal, publicKey: { challenge: challenge(), rpId: location.hostname,
                              userVerification: 'preferred' } })
    .then(function (c) {
      log('modal ' + c.id + ' ' + (c instanceof PublicKeyCredential));
      return fetch('/verify', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(c) });
    })
    .then(function (r) { return r.json(); })
    .then(function (v) { log('verified ' + v.ok); if (v.ok) location.href = '/home'; },
          function (e) { log('modal ' + e.name + ': ' + e.message); });
};
</script></body></html>"""


class Site(BaseHTTPRequestHandler):
    posted = []

    def send(self, body, kind="text/html"):
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.send("<!doctype html><title>home</title><p>signed in" if self.path.startswith("/home") else LOGIN)

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode("utf-8", "replace")
        Site.posted.append(body)
        try: ok = json.loads(body).get("id") == "from-extension"
        except ValueError: ok = False
        self.send(json.dumps({"ok": ok}), "application/json")

    def log_message(self, *a):
        pass


def extension():
    """A password manager's passkeys, as 1Password hands them over."""
    return {
        "manifest.json": json.dumps({
            "manifest_version": 3, "name": "Keeper of Keys", "version": "1.0",
            "background": {"service_worker": "sw.js"},
            "host_permissions": ["http://localhost/*"],
            "content_scripts": [
                {"matches": ["http://localhost/*"], "js": ["page.js"], "run_at": "document_start", "world": "MAIN"},
                {"matches": ["http://localhost/*"], "js": ["content.js"], "run_at": "document_start"},
            ],
            "web_accessible_resources": [{"resources": ["prompt.html", "prompt.js"], "matches": ["<all_urls>"]}],
        }),
        # The worker: a passkey "picked" `pick` ms after the request comes;
        # a request under the field waits until the next one takes its place.
        "sw.js": """
let waiting = null;
chrome.runtime.onMessage.addListener((m, sender, reply) => {
  if (m.slow) { setTimeout(() => reply({ late: true }), m.slow); return true; }
  if (!m.getCredential) return;
  if (waiting) { waiting({ error: 'user-cancelled' }); waiting = null; }
  if (m.getCredential.mediation === 'conditional') { waiting = reply; return true; }
  setTimeout(() => reply({ id: 'from-extension' }), m.getCredential.pick || 0);
  return true;
});
""",
        # In the page's own world, in place of navigator.credentials.get, as
        # 1Password's webauthn-listeners.js: the request goes to the content
        # script; a conditional one put away answers nothing; anything gone
        # wrong is asked of the browser instead.
        "page.js": """
(() => {
  const creds = navigator.credentials;
  const browserGet = creds.get.bind(creds);
  const ask = (body) => new Promise((resolve) => {
    const id = Math.random().toString(36).slice(2);
    addEventListener('message', function heard(e) {
      if (e.source !== window || !e.data || e.data.keeperReply !== id) return;
      removeEventListener('message', heard);
      resolve(e.data.body);
    });
    postMessage({ keeperAsk: id, body }, '*');
  });
  const bytes = (s) => new TextEncoder().encode(s).buffer;
  async function get(options) {
    if (!options || !options.publicKey) return browserGet(options);
    const reply = await ask({ mediation: options.mediation || 'optional', pick: Number(document.documentElement.dataset.pick || 0) });
    if (!reply || reply.error) {
      if (reply && reply.error === 'user-cancelled' && options.mediation === 'conditional') return new Promise(() => {});
      document.documentElement.dataset.fellBack = (document.documentElement.dataset.fellBack || '') + (options.mediation || 'modal') + ' ';
      return browserGet(options);
    }
    const response = { clientDataJSON: bytes('{}'), authenticatorData: bytes('auth'), signature: bytes('sig'), userHandle: null };
    Object.setPrototypeOf(response, AuthenticatorAssertionResponse.prototype);
    const credential = { id: reply.id, rawId: bytes(reply.id), type: 'public-key', authenticatorAttachment: 'cross-platform',
                         response, getClientExtensionResults: () => ({}), toJSON: () => ({ id: reply.id, type: 'public-key' }) };
    return Object.setPrototypeOf(credential, PublicKeyCredential.prototype);
  }
  const hook = (target, name, value) => Object.defineProperty(target, name, {
    configurable: false, enumerable: true, get() { return value; }, set() {} });
  hook(creds, 'get', get);
  hook(PublicKeyCredential, 'isConditionalMediationAvailable', async () => true);
})();
""",
        # The content script: carries the page's requests to the worker, and
        # puts the extension's prompt in the page, a frame of its own.
        "content.js": """
addEventListener('message', (e) => {
  if (e.source !== window || !e.data || !e.data.keeperAsk) return;
  const id = e.data.keeperAsk, t0 = Date.now();
  chrome.runtime.sendMessage({ getCredential: e.data.body }).then(
    (body) => { document.documentElement.dataset.replies = (document.documentElement.dataset.replies || '') + JSON.stringify([e.data.body.mediation, body === undefined ? 'nothing' : body, Date.now() - t0]); postMessage({ keeperReply: id, body }, '*'); },
    (error) => postMessage({ keeperReply: id, body: { error: String(error) } }, '*'));
}, true);
const prompt = () => {
  const frame = document.createElement('iframe');
  frame.src = chrome.runtime.getURL('prompt.html');
  frame.id = 'keeper-prompt';
  document.documentElement.appendChild(frame);
};
if (document.readyState === 'loading') addEventListener('DOMContentLoaded', prompt); else prompt();
// For the plain case: a message the worker answers late.
addEventListener('keeper-slow', (e) => {
  const started = Date.now();
  chrome.runtime.sendMessage(e.detail ? { slow: e.detail } : { nobody: 'answers' }).then(
    (r) => { document.documentElement.dataset.slow = JSON.stringify({ reply: r === undefined ? 'nothing' : r, after: Date.now() - started }); },
    (error) => { document.documentElement.dataset.slow = JSON.stringify({ error: String(error) }); });
});
""",
        # The prompt listens for messages of its own, and says nothing about
        # the rest, as 1Password's does.
        "prompt.html": "<!doctype html><script src=prompt.js></script><p>Pick a passkey",
        "prompt.js": "chrome.runtime.onMessage.addListener((m) => { if (m && m.prompt) document.body.dataset.told = '1'; });",
    }


def probe_copy():
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def loaded(name, within=20):
    end = time.time() + within
    while time.time() < end:
        ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == name and x["loaded"]), None)
        if ext:
            return ext
        time.sleep(0.5)
    return None


def until(tid, js, within):
    end = time.time() + within
    value = None
    while time.time() < end:
        try: value = sv.ev(tid, js)
        except RuntimeError: value = None
        if value:
            return value
        time.sleep(0.5)
    return value


def tab_url(tid):
    return next((x["url"] for x in sv.cmd({"do": "tabs"})["tabs"] if x["id"].startswith(tid)), "")


def sign_in(t, port, pick, label):
    Site.posted.clear()
    tid = sv.cmd({"do": "open", "url": f"http://localhost:{port}/login"})["id"]
    framed = until(tid, "document.getElementById('keeper-prompt') ? 'yes' : ''", 10)
    until(tid, "__log.indexOf('conditional available true') >= 0 ? 'yes' : ''", 5)
    sv.ev(tid, f"document.documentElement.dataset.pick = '{pick}'; 1")
    time.sleep(1)
    sv.cmd({"do": "click", "id": tid, "selector": "#passkey"})
    end = time.time() + pick / 1000 + 12
    while time.time() < end and "/home" not in tab_url(tid):
        time.sleep(0.5)
    url = tab_url(tid)
    t.ok(f"{label}: the extension's prompt is framed in the page", framed == "yes")
    t.ok(f"{label}: the extension's passkey reached the server", any('"from-extension"' in p for p in Site.posted), Site.posted)
    t.ok(f"{label}: and the tab moved on to the next page", url.endswith("/home"), url)
    if not url.endswith("/home"):
        print("     log:", sv.ev(tid, "JSON.stringify(window.__log)"), sv.ev(tid, "document.documentElement.dataset.replies"), "fell back:", sv.ev(tid, "document.documentElement.dataset.fellBack"))
    return tid


def main():
    t = sv.T()
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Site)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    port = srv.server_port
    folder = work / "ext"
    folder.mkdir()
    for name, body in extension().items():
        (folder / name).write_text(body)
    sv.APP = probe_copy()
    try:
        sv.setup()
        sv.launch()
        sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
        ext = loaded("Keeper of Keys")
        t.ok("the extension loads", ext is not None)
        if not ext:
            return t
        sv.cmd({"do": "ext-sites", "id": ext["id"], "mode": "all"})

        # Another tab with the extension's prompt framed in it, as 1Password
        # leaves its menu in every tab with a sign-in field: WebKit hands a
        # content script's message to the extension's pages in other tabs.
        other = sv.cmd({"do": "open", "url": f"http://localhost:{port}/other"})["id"]
        t.ok("another tab has the extension's prompt framed in it",
             until(other, "document.getElementById('keeper-prompt') ? 'yes' : ''", 10) == "yes")

        tid = sv.cmd({"do": "open", "url": f"http://localhost:{port}/plain"})["id"]
        until(tid, "document.getElementById('keeper-prompt') ? 'yes' : ''", 10)
        time.sleep(1.5)
        sv.ev(tid, "dispatchEvent(new CustomEvent('keeper-slow', { detail: 13000 })); 1")
        slow = until(tid, "document.documentElement.dataset.slow || ''", 20)
        got = json.loads(slow) if slow else None
        t.ok("a content script's message the worker answers after 13 s gets that answer",
             bool(got) and got.get("reply") == {"late": True}, got)

        # One nobody answers still ends, and no later than before.
        sv.ev(tid, "delete document.documentElement.dataset.slow; dispatchEvent(new CustomEvent('keeper-slow', { detail: 0 })); 1")
        slow = until(tid, "document.documentElement.dataset.slow || ''", 15)
        got = json.loads(slow) if slow else None
        t.ok("a message nobody answers still gets its nothing, within ten seconds",
             bool(got) and got.get("reply") == "nothing" and got.get("after", 99999) <= 10500, got)

        sign_in(t, port, 13000, "picked after 13 s")
        sign_in(t, port, 0, "picked at once")
    finally:
        sv.finish()
        for kind in ("WebKit", "Caches", "HTTPStorages"):
            shutil.rmtree(Path.home() / "Library" / kind / BUNDLE, ignore_errors=True)
        shutil.rmtree(work, ignore_errors=True)
    return t


if __name__ == "__main__":
    t = main()
    t.done()
    sys.exit(1 if t.failed else 0)
