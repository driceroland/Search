#!/usr/bin/env python3
"""An extension's own credentialed fetch to a site it has been granted
(ExtensionFetch.swift): sent with the site's SameSite=Lax cookies, as
Chrome sends it, and nothing else changed. In a hidden probe.

Build first (`./build.sh`), then `python3 Tests/panel_lax.py`. Hidden, in a
world of its own (split_view.py's harness), everything removed afterwards.
The stand-in site is http://localhost; tabs and other sites use
http://127.0.0.1, another site. Checked: the panel's fetch (and one shaped
like Claude in Chrome's bootstrap call, redirect "manual") carries the Lax
cookie; the panel's frame is still WebKit's (no Lax: ChatGPT's case); a
second extension without the grant, other sites' frames, a tab's cross-site
POST and a private tab get none; what the site sets reaches the tabs, still
Lax; `extensions.credentialedFetch` off stops it at once, no relaunch.

`python3 Tests/panel_lax.py real <file.crx>` loads a store package (named
by its id), presses its button and prints what went through ExtensionFetch
— addresses, statuses, cookie names, never a value. Use a fresh world only:
nothing is signed in there.

Every probe here is SIGKILLed 45 s after launch at the latest, or as soon as
the bench misses two pings a second apart: a wedged probe once crashed in its
sleep timer (~60 s in) with macOS's crash dialog on screen; SIGKILL leaves
neither.
"""
import json
import subprocess
import shutil
import sys
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("panel-lax")

# The guard (2 Nov: a wedged probe crashed in its sleep timer, ~60 s after
# launch, with macOS's crash dialog on screen). Every probe here is
# SIGKILLed — no crash report, no dialog — 45 s after launch whatever
# happens (the timer's first fire is 60 s in; tolerance only delays it), or
# as soon as the bench misses two pings a second apart. Runs fit in 45 s.
import os
import signal
import socket
CAP = 45
killed = []


def launch():
    born = time.time()
    stop = threading.Event()

    def kill(why):
        for p in set(sv.pids()) | sv.holding():
            try: os.kill(int(p), signal.SIGKILL)
            except (OSError, ValueError): pass
        killed.append(why); print("  WATCHDOG killed the probe:", why, flush=True)

    def ping():
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as c:
            c.settimeout(1.5); c.connect(sv.SOCK); c.sendall(b'{"do":"alive"}\n')
            if not c.recv(4096): raise OSError("no answer")

    def watch():
        misses, up = 0, False
        while not stop.wait(1.0):
            if time.time() - born > CAP: return kill(f"{CAP} s cap")
            try: ping(); misses, up = 0, True
            except OSError:
                if up: misses += 1
            if misses >= 2 or (not up and time.time() - born > 25): return kill("bench stopped answering")
    threading.Thread(target=watch, daemon=True).start()
    sv.launch()
    return stop
seen = {}  # path -> the Cookie header the site was sent
bodies = {}  # path -> the body a POST brought


class Site(BaseHTTPRequestHandler):
    def reply(self, body, headers=()):
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        for k, v in headers: self.send_header(k, v)
        self.end_headers(); self.wfile.write(body.encode())

    def do_POST(self):
        path = self.path.split("?")[0]
        seen[path] = seen[self.path] = self.headers.get("Cookie") or ""
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode(errors="replace")
        bodies[self.path] = body
        if path == "/echo":
            self.send_response(200); self.send_header("Content-Type", "text/plain"); self.end_headers()
            self.wfile.write(body.encode()); return
        self.reply("<!doctype html><title>posted</title>")

    def do_GET(self):
        path = self.path.split("?")[0]
        seen[path] = self.headers.get("Cookie") or ""
        seen[self.path] = seen[path]
        port = self.server.server_port
        if path == "/login":
            self.reply("<!doctype html><title>signed in</title>", [("Set-Cookie", c) for c in (
                "lax=1; Path=/; Max-Age=3600; SameSite=Lax", "none=1; Path=/; Max-Age=3600; SameSite=None",
                "plain=1; Path=/; Max-Age=3600")])
        elif path == "/rotate":  # the site renews its session, from inside the panel
            self.reply("<!doctype html>rotated", [("Set-Cookie", "lax=2; Path=/; Max-Age=3600; SameSite=Lax")])
        elif path == "/logout":
            self.reply("<!doctype html><title>out</title>", [("Set-Cookie", "lax=; Path=/; Max-Age=0; SameSite=Lax")])
        elif path == "/away":  # a redirect to a site the extension isn't granted
            self.send_response(302); self.send_header("Location", f"http://127.0.0.1:{port}/landed"); self.end_headers()
        elif path == "/foreign":  # a response that would set cookies it may not
            self.reply("ok", [("Set-Cookie", "x=1; Path=/; Domain=example.com"), ("Set-Cookie", "y=1; Path=/; Domain=localhost.evil")])
        elif path == "/bounce":  # a redirect, for redirect: "manual"
            self.send_response(302); self.send_header("Location", f"http://localhost:{port}/api?bounced"); self.end_headers()
        elif path in ("/api", "/api/bootstrap"):
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
            self.wfile.write(json.dumps({"cookie": seen[path]}).encode())
        elif path == "/frame":
            # The site in the panel: says what it reads, answers what it is
            # sent with where it came from, and frames a third party.
            self.reply(f"""<!doctype html><script>
addEventListener('message', e => parent.postMessage({{pong: e.data && e.data.ping, from: e.origin}}, '*'));
parent.postMessage({{frame: document.cookie || 'none'}}, '*');
</script><iframe src="http://127.0.0.1:{port}/evil?inside"></iframe>""")
        elif path == "/evil":
            # Another site, framed: asks the site with credentials.
            self.reply(f"""<!doctype html><script>fetch('http://localhost:{port}/api?' + location.search.slice(1),
  {{credentials: 'include', mode: 'no-cors'}}).catch(() => 0)</script>""")
        elif path == "/csrf":  # another site, in a tab, posting to the site
            self.reply(f"""<!doctype html><form method=post action="http://localhost:{port}/post"><input name=a value=1></form>
<script>document.forms[0].submit()</script>""")
        else:
            self.reply("<!doctype html>")

    def log_message(self, *a): pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), Site)
threading.Thread(target=srv.serve_forever, daemon=True).start()
SITE = f"http://localhost:{srv.server_port}"
OTHER = f"http://127.0.0.1:{srv.server_port}"
work = Path(tempfile.mkdtemp(prefix="search-panellax-"))

PANEL_JS = f"""
window.result = {{}};
addEventListener('message', e => {{
  if (e.data && e.data.frame) {{
    window.result.frame = e.data.frame; window.result.frameOrigin = e.origin;
    window.result.sourceIsFrame = e.source === f.contentWindow;
    f.contentWindow.postMessage({{ping: 'wrong'}}, 'http://elsewhere.invalid');
    f.contentWindow.postMessage({{ping: 'right'}}, '{SITE}');
  }}
  if (e.data && e.data.pong) (window.result.pongs = window.result.pongs || []).push(e.data.pong + '@' + e.data.from);
}});
const evil = document.createElement('iframe'); evil.src = '{OTHER}/evil?panel-third-party'; document.body.append(evil);
fetch('{SITE}/api?panel', {{credentials: 'include', cache: 'no-store'}})
  .then(r => r.json()).then(j => window.result.fetch = j.cookie || 'none', e => window.result.fetch = 'error: ' + e);
var f = document.createElement('iframe'); f.src = '{SITE}/frame?panel'; f.style.width = '300px'; f.style.height = '200px';
f.addEventListener('load', () => {{ window.result.loads = (window.result.loads || 0) + 1; window.result.src = f.src; }});
document.body.append(f);
// As Claude in Chrome asks claude.ai/api/bootstrap.
fetch('{SITE}/api/bootstrap', {{credentials: 'include', cache: 'no-store', redirect: 'manual', signal: AbortSignal.timeout(10000)}})
  .then(r => r.json()).then(j => window.result.bootstrap = j.cookie, e => window.result.bootstrap = 'error: ' + e);
// A Request with a body, no credentials: the page's own fetch, body intact.
fetch(new Request('{SITE}/echo?plain', {{method: 'POST', body: 'plain body'}}))
  .then(r => r.text()).then(t => window.result.plainBody = t, e => window.result.plainBody = 'error: ' + e);
// The same with credentials: through the browser, body and Lax cookie.
fetch(new Request('{SITE}/echo?credentialed', {{method: 'POST', body: 'credentialed body', credentials: 'include'}}))
  .then(r => r.text()).then(t => window.result.credBody = t, e => window.result.credBody = 'error: ' + e);
fetch('{SITE}/away', {{credentials: 'include'}})
  .then(r => window.result.away = 'followed:' + r.status, e => window.result.away = 'error: ' + e);
fetch('{SITE}/foreign', {{credentials: 'include'}}).then(r => window.result.foreign = r.status, e => window.result.foreign = 'error');
fetch('{SITE}/bounce', {{credentials: 'include', redirect: 'manual'}})
  .then(r => window.result.manual = r.type + ':' + r.status, e => window.result.manual = 'error: ' + e);
"""


def make(name, hosts):
    folder = work / name.replace(" ", "")
    folder.mkdir()
    (folder / "manifest.json").write_text(json.dumps({
        "manifest_version": 3, "name": name, "version": "1.0",
        "permissions": ["sidePanel", "storage"], "host_permissions": hosts,
        "side_panel": {"default_path": "panel.html"},
    }))
    (folder / "panel.html").write_text("<!doctype html><title>panel</title><body><script src=panel.js></script>")
    (folder / "panel.js").write_text(PANEL_JS)
    (folder / "page.html").write_text("<!doctype html><title>own</title>")
    return str(folder)


def add(path, name):
    sv.cmd({"do": "ext-folder", "path": path, "yes": True})
    for _ in range(50):
        found = [x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == name and x["loaded"]]
        if found: return found[0]
        time.sleep(0.2)
    raise RuntimeError(f"{name} didn't load")


def panel_eval(js):
    try:
        return sv.cmd({"do": "sidepanel", "action": "eval", "js": js}).get("value")
    except RuntimeError:
        return None


def open_panel(ext):
    seen.clear()
    page = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "page.html"})["id"]
    time.sleep(1.0)
    sv.cmd({"do": "eval", "id": page, "js": "chrome.sidePanel.open({windowId: 1}); 1"})
    got = {}
    for _ in range(40):
        time.sleep(0.25)
        try: got = json.loads(panel_eval("JSON.stringify(window.result || {})") or "{}")
        except ValueError: got = {}
        if "fetch" in got and "frame" in got: break
    return got, seen.get("/api"), seen.get("/frame")


def panel_fetch(path):
    """A fetch with credentials from the open panel; what the site was sent."""
    seen.pop(path.split("?")[0], None)
    panel_eval(f"fetch('{SITE}{path}', {{credentials: 'include', cache: 'no-store'}}).catch(() => 0); 1")
    for _ in range(20):
        time.sleep(0.2)
        if path.split("?")[0] in seen: break
    return seen.get(path.split("?")[0])


def tab_sent(path):
    """What the site is sent by a tab opening it (first-party)."""
    seen.pop(path, None)
    sv.cmd({"do": "open", "url": f"{SITE}{path}"})
    for _ in range(20):
        time.sleep(0.2)
        if path in seen: break
    return seen.get(path)


def start():
    sv.setup(sidebar=True)
    return launch()


def main():
    t = sv.T()
    access = make("Lax Access", ["http://localhost/*"])
    without = make("Lax Without", [])
    stop = None
    began = time.time()
    try:
        stop = start()
        sv.cmd({"do": "open", "url": f"{SITE}/login"}); time.sleep(1.0)

        ext = add(access, "Lax Access")
        got, api, frame = open_panel(ext)
        for _ in range(12):
            if all(got.get(k) for k in ("bootstrap", "manual", "plainBody", "credBody", "away", "foreign")): break
            time.sleep(0.25)
            try: got = json.loads(panel_eval("JSON.stringify(window.result || {})") or "{}")
            except ValueError: pass
        time.sleep(0.5)
        print("  with access:", got, "| site sent: api", repr(seen.get("/api?panel")), "frame", repr(seen.get("/frame?panel")))
        t.ok("the panel's own fetch sends the Lax cookie", "lax=1" in (seen.get("/api?panel") or ""), seen.get("/api?panel"))
        t.ok("its answer reads", "lax=1" in got.get("fetch", ""), got)
        t.ok("a call shaped like Claude's bootstrap (redirect manual, no-store, timeout signal) sends it",
             "lax=1" in (got.get("bootstrap") or ""), got.get("bootstrap"))
        t.ok("redirect manual answers an opaque redirect, not followed",
             got.get("manual") == "opaqueredirect:0" and "/api?bounced" not in seen, (got.get("manual"), "/api?bounced" in seen))
        t.ok("a Request with a body and no credentials still goes, body intact (WebKit's own fetch)",
             got.get("plainBody") == "plain body" and bodies.get("/echo?plain") == "plain body", (got.get("plainBody"), bodies.get("/echo?plain")))
        t.ok("a Request with a body and credentials goes through the browser, body intact, Lax sent",
             got.get("credBody") == "credentialed body" and "lax=1" in (seen.get("/echo?credentialed") or ""), (got.get("credBody"), seen.get("/echo?credentialed")))
        t.ok("a redirect to a site the extension isn't granted fails, the site never asked",
             str(got.get("away", "")).startswith("error") and "/landed" not in seen, (got.get("away"), "/landed" in seen))
        # The panel's frame is WebKit's own: still no Lax (ChatGPT's case,
        # until WebKit's fix ships); its messages still work.
        t.ok("the panel's frame is unchanged: no Lax cookie (WebKit's limit)",
             "lax=" not in (seen.get("/frame?panel") or "x") and "lax=" not in got.get("frame", "x"), (seen.get("/frame?panel"), got.get("frame")))
        t.ok("the panel's frame still talks to the page", got.get("sourceIsFrame") is True and got.get("frameOrigin") == SITE, got)
        t.ok("a third-party frame in the panel: no Lax cookie with its request",
             "lax=" not in (seen.get("/api?panel-third-party") or ""), seen.get("/api?panel-third-party"))
        trace = sv.cmd({"do": "ext-fetches"})["trace"]
        natives = [x for x in trace if "native" in x]
        refused = sorted(x["refused"] for x in trace if "refused" in x)
        print("  refused cookies:", refused)
        t.ok("a response may not set another domain's cookies", refused == ["x", "y"], refused)
        print("  trace:", json.dumps(natives[:4]))
        t.ok("it went natively, from the extension's origin, with the window's space store",
             any(x["native"].endswith("/api/bootstrap") and "lax" in x["cookies"] and x["store"] == "space"
                 and x["origin"].endswith("://" + ext["id"]) for x in natives), natives)
        t.ok("the extension page runs (chrome.storage answers)",
             panel_eval("typeof chrome.storage.local.get") == "function")

        # Renewed through the panel's fetch: reaches the tabs, still Lax there.
        panel_fetch("/rotate"); time.sleep(0.6)
        in_tab = tab_sent("/whoami")
        print("  after a renewal from the panel: a tab sends", repr(in_tab))
        t.ok("a cookie the site sets for the panel reaches the tabs", "lax=2" in (in_tab or ""), in_tab)
        seen.pop("/post", None)
        sv.cmd({"do": "open", "url": f"{OTHER}/csrf"})
        for _ in range(20):
            time.sleep(0.2)
            if "/post" in seen: break
        print("  cross-site POST from a tab: site sent", repr(seen.get("/post")))
        t.ok("tabs keep Lax: another site's POST from a tab arrives without it",
             "/post" in seen and "lax=" not in seen.get("/post"), seen.get("/post"))

        seen.pop("/whoami", None)
        sv.cmd({"do": "open", "url": f"{SITE}/whoami", "private": True})
        for _ in range(20):
            time.sleep(0.2)
            if "/whoami" in seen: break
        print("  private tab: site sent", repr(seen.get("/whoami")))
        t.ok("a private tab is sent no cookie of the profile's", "/whoami" in seen and not seen.get("/whoami"), seen.get("/whoami"))

        # The kill switch, while running: off at once, back on at once.
        subprocess.run(["defaults", "write", sv.SUITE, "extensions.credentialedFetch", "-bool", "false"]); time.sleep(0.5)
        off = panel_fetch("/api?switched-off")
        subprocess.run(["defaults", "delete", sv.SUITE, "extensions.credentialedFetch"], capture_output=True); time.sleep(0.5)
        back = panel_fetch("/api?switched-on")
        print("  kill switch: off sent", repr(off), "| on again sent", repr(back))
        t.ok("extensions.credentialedFetch off: WebKit's fetch again, no Lax, no relaunch", off is not None and "lax=" not in off, off)
        t.ok("and on again by default", "lax=2" in (back or ""), back)
        sv.cmd({"do": "sidepanel", "action": "close"})

        sv.cmd({"do": "ext-remove", "id": ext["id"]}); time.sleep(0.5)
        other = add(without, "Lax Without")
        got, api, frame = open_panel(other)
        time.sleep(0.5)
        print("  without the grant:", got, "| site sent: api", repr(seen.get("/api?panel")))
        t.ok("without the grant: its fetch carries no Lax cookie", "lax=" not in (seen.get("/api?panel") or ""), seen.get("/api?panel"))
        t.ok("without the grant: its fetch's answer stays unread", got.get("fetch", "").startswith("error"), got)
        t.ok("without the grant: the Claude-shaped call carries none either", "lax=" not in (seen.get("/api/bootstrap") or ""), seen.get("/api/bootstrap"))
        sv.cmd({"do": "sidepanel", "action": "close"})
        t.ok("nothing reached a screen", "onScreen" not in sv.cmd({"do": "probe"}))
        print(f"  ran {time.time() - began:.0f}s")
    except Exception as e:
        t.failed += 1; print(f"  FAIL stopped: {type(e).__name__}: {e}")
    finally:
        if stop: stop.set()
        t.ok("the watchdog never had to fire", not killed, killed)
        t.done(); sv.finish(); shutil.rmtree(work, ignore_errors=True)
    sys.exit(1 if t.failed else 0)


def real(crx, wait=22):
    """A store package (its file named by its id), verified and installed as
    from the store, its button pressed. Prints what went through
    ExtensionFetch: addresses, statuses, cookie names, never a value."""
    store_id = Path(crx).stem
    stop = None
    try:
        stop = start()
        sv.cmd({"do": "ext-answer", "answer": "yes"})
        sv.cmd({"do": "ext-crx", "path": crx, "id": store_id})
        ext = None
        for _ in range(60):
            found = [x for x in sv.cmd({"do": "extensions"})["extensions"] if x["id"] == store_id and x["loaded"]]
            if found: ext = found[0]; break
            time.sleep(0.2)
        print(f"  [{store_id}] loaded:", bool(ext), flush=True)
        if not ext: return
        sv.cmd({"do": "open", "url": f"{SITE}/whoami"}); time.sleep(1.0)
        sv.cmd({"do": "ext-press", "id": ext["id"]})
        time.sleep(wait / 2)
        state = sv.cmd({"do": "sidepanel"})
        print(f"  [{ext['name']}] panel: shown={state.get('shown')} page={state.get('page')!r}", flush=True)
        if state.get("shown") and not any("native" in x for x in sv.cmd({"do": "ext-fetches"})["trace"]):
            print(f"  [{ext['name']}] no credentialed fetch yet; the bootstrap call Claude's page makes, from its page:", flush=True)
            panel_eval("fetch('https://claude.ai/api/bootstrap', {credentials: 'include', cache: 'no-store', redirect: 'manual', signal: AbortSignal.timeout(10000)}).then(r => window.__probe = r.type + ':' + r.status, e => window.__probe = 'error ' + e); 1")
            time.sleep(3)
            print(f"  [{ext['name']}] its answer:", panel_eval("window.__probe"), flush=True)
        for x in sv.cmd({"do": "ext-fetches"})["trace"]:
            print(f"  [{ext['name']}] trace:", json.dumps(x), flush=True)
        sv.cmd({"do": "sidepanel", "action": "close"})
        print(f"  [{ext['name']}] on screen:", "onScreen" in sv.cmd({"do": "probe"}), flush=True)
    except Exception as e:
        print(f"  stopped: {type(e).__name__}: {e}", flush=True)
    finally:
        if stop: stop.set()
        sv.finish(); shutil.rmtree(work, ignore_errors=True)
        print("  watchdog:", killed or "never fired", flush=True)


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "real":
        real(sys.argv[2])
    else:
        main()
