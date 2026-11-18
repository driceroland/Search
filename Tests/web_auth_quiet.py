#!/usr/bin/env python3
"""chrome.identity.launchWebAuthFlow without interactive: true, in a hidden
probe.

Build first (`./build.sh`), then `python3 Tests/web_auth_quiet.py`. It runs
in a world of its own with split_view.py's harness: started hidden,
everything removed afterwards.

Claude in Chrome keeps its sign-in in storage.session, which every browser
empties when it quits, and gets it back at the next start with a
non-interactive flow (interactive: false, abortOnLoadForNonInteractive:
false, timeoutMsForNonInteractive: 15000) on claude.ai's authorize page.
Chrome runs such a flow out of sight; Search opened a tab in front for it.
Without its sign-in the extension never joins Anthropic's bridge, and the
Claude app says it "couldn't reach Claude in Chrome" (18 Oct 2026).

The stand-in: a provider on http://localhost that sends the browser on to
the extension's https://<id>.chromiumapp.org/ at once, after a script's
pause, or never, and an extension page that starts each kind of flow.
Checked: a quiet flow opens no tab, comes back with the address, carries the
front space's cookies (SameSite=Lax included, as a page loaded at the top
does), ends at load or at its time as Chrome's does, answers only for the
extension's own address, and lets the page open no window or dialog. An
interactive flow still gets its tab.
"""
import json
import shutil
import sys
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("web-auth-quiet")
EXT = {"id": None}
seen = {}


class Provider(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        seen[path] = self.headers.get("Cookie") or ""
        back = f"https://{EXT['id']}.chromiumapp.org/cb"
        headers = [("Content-Type", "text/html")]
        status, body = 200, "<!doctype html><title>provider</title>"
        if path == "/login":
            headers.append(("Set-Cookie", "lax=1; Path=/; Max-Age=600; SameSite=Lax"))
            body = "<!doctype html><title>signed in</title>"
        elif path == "/now":
            status = 302
            headers.append(("Location", f"{back}?code=now&cookie={'lax' if 'lax=1' in seen[path] else 'none'}"))
        elif path == "/later":
            body = f"<!doctype html><title>wait</title><script>setTimeout(() => location = '{back}?code=later', 800)</script>"
        elif path == "/elsewhere":
            status = 302
            headers.append(("Location", "https://abcdefghijklmnopabcdefghijklmnop.chromiumapp.org/cb?code=stolen"))
        elif path == "/plainhttp":
            status = 302
            headers.append(("Location", f"http://{EXT['id']}.chromiumapp.org/cb?code=plain"))
        elif path == "/sneaky":
            # Other chromiumapp.org shapes: none may load, the flow just fails.
            status = 302
            headers.append(("Location", f"https://{EXT['id']}.chromiumapp.org.evil.test/cb?code=sneaky"))
        elif path == "/report":
            # What the page out of sight may do, sent back on the redirect.
            body = f"""<!doctype html><title>report</title><script>
(async () => {{
  const r = {{}};
  r.pk = typeof window.PublicKeyCredential;
  try {{ r.uvpa = await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable(); }} catch (e) {{ r.uvpa = e.name; }}
  try {{ await navigator.credentials.get({{publicKey: {{challenge: new Uint8Array(16)}}}}); r.webauthn = 'answered'; }}
  catch (e) {{ r.webauthn = e.name; }}
  const media = navigator.mediaDevices && navigator.mediaDevices.getUserMedia
    ? Promise.race([navigator.mediaDevices.getUserMedia({{audio: true}}).then(() => 'granted', e => e.name),
                    new Promise(ok => setTimeout(() => ok('held'), 1500))])
    : Promise.resolve('none');
  r.mic = await media;
  const a = new Audio('data:audio/wav;base64,UklGRiQAAABXQVZFZm10IBAAAAABAAEAQB8AAIA+AAACABAAZGF0YQAAAAA=');
  r.play = await Promise.race([a.play().then(() => 'played', e => e.name), new Promise(ok => setTimeout(() => ok('held'), 1000))]);
  r.prompt = String(prompt('x', 'y'));
  location = '{back}?r=' + encodeURIComponent(JSON.stringify(r));
}})();
</script>"""
        elif path == "/noisy":
            body = "<!doctype html><title>noisy</title><script>window.open('about:blank'); alert('hi'); confirm('?')</script>"
        self.send_response(status)
        for k, v in headers: self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body.encode())

    def log_message(self, *a): pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
threading.Thread(target=srv.serve_forever, daemon=True).start()
SITE = f"http://localhost:{srv.server_port}"
work = Path(tempfile.mkdtemp(prefix="search-webauth-"))


def make():
    folder = work / "auth"
    folder.mkdir()
    (folder / "manifest.json").write_text(json.dumps({
        "manifest_version": 3, "name": "Quiet Auth", "version": "1.0", "permissions": ["identity"]}))
    (folder / "page.html").write_text("<!doctype html><title>auth</title>")
    return str(folder)


def flow(page, options, within=20):
    """Starts a flow from the extension page and waits for its outcome."""
    sv.ev(page, f"""window.__r = undefined; window.__t = Date.now();
chrome.identity.launchWebAuthFlow({json.dumps(options)})
  .then(u => window.__r = {{ok: u, ms: Date.now() - window.__t}},
        e => window.__r = {{error: String(e && e.message || e), ms: Date.now() - window.__t}}); 1""")
    for _ in range(int(within / 0.2)):
        time.sleep(0.2)
        got = sv.ev(page, "JSON.stringify(window.__r || null)")
        if got and got != "null": return json.loads(got)
    return None


def tabs(): return [t.get("url", "") for t in sv.cmd({"do": "tabs"}).get("tabs", [])]


def main():
    t = sv.T()
    folder = make()
    try:
        sv.setup(sidebar=True); sv.launch()
        sv.cmd({"do": "open", "url": f"{SITE}/login"}); time.sleep(1.0)
        sv.cmd({"do": "ext-folder", "path": folder, "yes": True})
        ext = None
        for _ in range(50):
            found = [x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == "Quiet Auth" and x["loaded"]]
            if found: ext = found[0]; break
            time.sleep(0.2)
        EXT["id"] = ext["id"]
        page = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "page.html"})["id"]
        time.sleep(1.0)
        before = tabs()

        r = flow(page, {"url": f"{SITE}/now", "interactive": False})
        print("  straight back:", r)
        t.ok("quiet: a redirect straight back is the answer", r and "code=now" in (r.get("ok") or ""), r)
        t.ok("quiet: the front space's cookies go with it, Lax included", r and "cookie=lax" in (r.get("ok") or ""), r)
        t.ok("quiet: no tab opened", tabs() == before, (before, tabs()))

        r = flow(page, {"url": f"{SITE}/now"})
        t.ok("interactive left out = quiet, as in Chrome", r and "code=now" in (r.get("ok") or "") and tabs() == before, r)

        r = flow(page, {"url": f"{SITE}/later", "interactive": False, "abortOnLoadForNonInteractive": False,
                        "timeoutMsForNonInteractive": 15000})
        print("  after a script:", r)
        t.ok("quiet, told to wait: a script's redirect is the answer", r and "code=later" in (r.get("ok") or ""), r)

        r = flow(page, {"url": f"{SITE}/later", "interactive": False})
        print("  ends at load:", r)
        t.ok("quiet: a page that loads ends the flow (abortOnLoad default)",
             r and "interaction required" in (r.get("error") or "").lower(), r)

        r = flow(page, {"url": f"{SITE}/plain", "interactive": False, "abortOnLoadForNonInteractive": False,
                        "timeoutMsForNonInteractive": 1500})
        print("  timed out:", r)
        t.ok("quiet: a page that stays ends at the extension's time",
             r and "interaction required" in (r.get("error") or "").lower() and 1300 <= r.get("ms", 0) < 6000, r)

        r = flow(page, {"url": f"{SITE}/elsewhere", "interactive": False})
        print("  another id's address:", r)
        t.ok("quiet: another extension's address is no answer", r and "error" in r and "stolen" not in json.dumps(r), r)

        r = flow(page, {"url": f"{SITE}/plainhttp", "interactive": False, "abortOnLoadForNonInteractive": False,
                        "timeoutMsForNonInteractive": 8000})
        print("  own id over http:", r)
        t.ok("quiet: its own address over http is no answer, and fails at once",
             r and "error" in r and "plain" not in json.dumps(r) and r.get("ms", 9999) < 4000, r)

        r = flow(page, {"url": f"{SITE}/sneaky", "interactive": False})
        t.ok("quiet: <id>.chromiumapp.org.<elsewhere> is no answer", r and "error" in r and "sneaky" not in json.dumps(r), r)

        r = flow(page, {"url": f"{SITE}/report", "interactive": False, "abortOnLoadForNonInteractive": False,
                        "timeoutMsForNonInteractive": 15000})
        print("  what the page may do:", r)
        got = {}
        try:
            from urllib.parse import urlparse, parse_qs
            got = json.loads(parse_qs(urlparse(r["ok"]).query)["r"][0])
        except Exception:
            pass
        t.ok("quiet: the passkey object says there are none", got.get("pk") == "function" and got.get("uvpa") is False, got)
        t.ok("quiet: a passkey request is refused, not handed to WebKit", got.get("webauthn") == "NotAllowedError", got)
        t.ok("quiet: the microphone is refused (or never asked)", got.get("mic") in ("NotAllowedError", "held", "none"), got)
        t.ok("quiet: no sound plays", got.get("play") in ("NotAllowedError", "held"), got)
        t.ok("quiet: prompt() answers nothing", got.get("prompt") == "null", got)

        r = flow(page, {"url": f"{SITE}/noisy", "interactive": False, "abortOnLoadForNonInteractive": False,
                        "timeoutMsForNonInteractive": 2000})
        t.ok("quiet: a page's window.open/alert/confirm shows nothing and the flow still ends", r and "error" in r, r)
        t.ok("quiet: no tab after all of them", tabs() == before, (before, tabs()))

        r = flow(page, {"url": "file:///etc/hosts", "interactive": False})
        t.ok("quiet: only http(s)", r and "error" in r, r)

        # Unchanged: interactive gets its tab, which the redirect then closes.
        r = flow(page, {"url": f"{SITE}/now", "interactive": True})
        print("  interactive:", r)
        t.ok("interactive: still answered through its tab", r and "code=now" in (r.get("ok") or ""), r)
        t.ok("interactive: its tab gone again", tabs() == before, (before, tabs()))
        t.ok("nothing reached a screen", "onScreen" not in sv.cmd({"do": "probe"}))
    finally:
        t.done(); sv.finish(); shutil.rmtree(work, ignore_errors=True)
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
