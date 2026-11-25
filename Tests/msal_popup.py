#!/usr/bin/env python3
"""A sign-in pop-up the way Microsoft's MSAL.js opens one (idea 1200: Teams'
"sign in again" banner, whose Sign in button did nothing), in a hidden probe.

Only local fixtures: the app is 127.0.0.1, its "identity provider" is
localhost (another site), and the provider signs in at once with a fake code,
as it does for someone with a session. Each button is one shape of MSAL's
acquireTokenPopup:

- sync: the window is opened at the click, empty (about:blank), sized, and
  only sent to the provider after some async work (MSAL's default);
- async: the async work first, then window.open straight to the provider
  (MSAL's asyncPopups), 0.6 s after the click;
- route: the app sets location.hash on the click first, then opens the
  window, as single-page apps' routers do (refused before the fix: a
  same-page #fragment jump counted as leaving the page);
- the result is read by polling the window's address until it is back on the
  app's own site (MSAL v2/v3), or posted on a BroadcastChannel by the
  redirect page (v4); then the window is closed.

Run with sized pop-ups in small windows on (the default since 25 Nov) and off.
Build first (`./build.sh debug`), then
`lockf -t 900 /private/tmp/claude-501/search-probe.lock.N python3 Tests/msal_popup.py`.
"""
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse, parse_qs

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("msal-popup")
PORT = sv.srv.server_port
APP = f"http://127.0.0.1:{PORT}"
IDP = f"http://localhost:{PORT}"

OPENER = """<h1>App</h1><div id=banner>Your session needs you to sign in again.
<button id=sync>Sign in</button> <button id=async>Sign in (async)</button>
<button id=channel>Sign in (v4)</button> <button id=hash>Sign in (route)</button></div>
<script>
window.result = 'idle';
const features = 'width=483,height=600,top=100,left=300';
const authorize = (state) => '%(idp)s/authorize?redirect_uri=' + encodeURIComponent('%(app)s/redirect') + '&state=' + state;
const work = () => fetch('/delay').then(r => r.text()).then(() => crypto.subtle.digest('SHA-256', new TextEncoder().encode('verifier')));
function poll(popup, state) {
  const started = Date.now();
  const timer = setInterval(() => {
    if (!popup || popup.closed) { clearInterval(timer); if (result === 'waiting') result = 'user_cancelled'; return; }
    let href = '';
    try { href = popup.location.href; } catch (e) { return; }
    if (href.startsWith('%(app)s/redirect') && href.includes('code=')) {
      clearInterval(timer);
      result = href.includes('state=' + state) ? 'signed in' : 'state mismatch';
      popup.close();
    } else if (Date.now() - started > 15000) { clearInterval(timer); result = 'timed out at ' + href; }
  }, 30);
}
document.getElementById('sync').onclick = async () => {
  result = 'waiting';
  const popup = window.open('about:blank', 'msal.sync', features);
  if (!popup) { result = 'popup_window_error'; return; }
  await work();
  popup.location.assign(authorize('s1'));
  poll(popup, 's1');
};
document.getElementById('async').onclick = async () => {
  result = 'waiting';
  await work();
  const popup = window.open(authorize('s2'), 'msal.async', features);
  if (!popup) { result = 'popup_window_error'; return; }
  poll(popup, 's2');
};
// The app notes the step in its address first (a #route), then opens the
// window, as an SPA's router does: same page, same click.
document.getElementById('hash').onclick = async () => {
  result = 'waiting';
  location.hash = '/signin';
  const popup = window.open('about:blank', 'msal.hash', features);
  if (!popup) { result = 'popup_window_error'; return; }
  await work();
  popup.location.assign(authorize('s4'));
  poll(popup, 's4');
};
document.getElementById('channel').onclick = async () => {
  result = 'waiting';
  const popup = window.open('about:blank', 'msal.v4', features);
  if (!popup) { result = 'popup_window_error'; return; }
  const channel = new BroadcastChannel('msal.s3');
  channel.onmessage = (e) => { result = String(e.data).includes('code=') ? 'signed in' : 'bad message'; channel.close(); popup.close(); };
  await work();
  popup.location.assign(authorize('s3') + '&v=4');
  const t = setInterval(() => { if (popup.closed) { clearInterval(t); if (result === 'waiting') result = 'user_cancelled'; } }, 50);
};
</script>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)
        q = parse_qs(url.query)
        if url.path == "/delay":
            time.sleep(0.5)
            body = "ok"
        elif url.path == "/teams":
            body = OPENER % {"app": APP, "idp": IDP}
        elif url.path == "/authorize":
            # Someone with a session: straight back with a code, as
            # login.microsoftonline.com does after a moment.
            back = q.get("redirect_uri", [""])[0] + "#code=fake-test-code&state=" + q.get("state", [""])[0]
            v4 = q.get("v", [""])[0] == "4"
            if v4: back = back.replace("/redirect#", "/redirect?v=4#")
            body = f"<p>Signing you in…<script>setTimeout(() => location.replace({back!r}), 400)</script>"
        elif url.path == "/redirect":
            body = ("<p>redirect<script>if (new URLSearchParams(location.search).get('v') === '4') {"
                    " const s = new URLSearchParams(location.hash.slice(1)).get('state');"
                    " new BroadcastChannel('msal.' + s).postMessage(location.hash); }</script>")
        else:
            body = url.path
        data = f"<!doctype html><meta charset=utf-8><title>{url.path}</title>{body}".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a): pass


sv.srv.RequestHandlerClass = H


def windows():
    return sv.cmd({"do": "windows"})["windows"]


def tabs(window=1):
    return sv.cmd({"do": "tabs", "window": window})["tabs"]


def result(page, within=8.0):
    end = time.time() + within
    value = sv.ev(page, "result")
    # "idle" too: the tap can come back before the page has had the click.
    while value in ("idle", "waiting") and time.time() < end:
        time.sleep(0.25)
        value = sv.ev(page, "result")
    return value


def run(t, small, report):
    sv.setup(**{"tabs.popupWindows": small})
    sv.launch()
    label = "small windows" if small else "tabs"
    page = sv.page("teams")
    for button in ("sync", "async", "channel", "hash"):
        before = (len(windows()), len(tabs()))
        sv.cmd({"do": "tap", "id": page, "selector": "#" + button})
        got = result(page)
        sv.ev(page, "result = 'idle', true")
        time.sleep(0.6)
        after = (len(windows()), len(tabs()))
        report.append((f"{label}: {button}", got, before, after, [x["url"] for x in tabs()]))
        t.ok(f"{label}: {button}: signed in through the pop-up", got == "signed in", got)
        t.ok(f"{label}: {button}: the pop-up closed after", after == before, (before, after))
    sv.quit()


def main():
    t = sv.T()
    report = []
    try:
        run(t, True, report)
        run(t, False, report)
    finally:
        sv.finish()
    return t, report


if __name__ == "__main__":
    t, report = main()
    print("\nwhat it saw:")
    for line in report:
        print("  ", line)
    t.done()
    sys.exit(1 if t.failed else 0)
