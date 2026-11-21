#!/usr/bin/env python3
"""What a site keeps — a server's HttpOnly cookie, a script's cookie, local
storage, a framed site's cookie — survives ⌘Q and a relaunch, in a hidden
probe (idea 838).

Build first (`./build.sh debug`), then `python3 Tests/cookies_survive_quit.py`.
Each case sets everything on a local page, quits the way ⌘Q does right
after (or ten seconds after) and starts the same world again: the next page
must be sent and see all of it. With Prevent cross-site tracking on and off.
Nothing here makes, shows or brings forward a window.
"""
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

sv.use("cookies-quit")

# The real browser keeps the main profile's sites in WebKit's default store;
# a probe under Search's own bundle id gets a store made by identifier
# instead (Store.websites). A copy under a bundle id of its own uses the
# default store, as the real browser does, so both are tried.
BUNDLE = "com.officecommun.search.cookiesquit"
HOME = str(Path.home())
work = Path(tempfile.mkdtemp(prefix="search-cookiesquit-"))


def own_copy():
    app = work / "Search.app"
    shutil.rmtree(app, ignore_errors=True)
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def forget_copy():
    """The copy's own WebKit container: its default store, by its bundle id."""
    for path in [f"{HOME}/Library/WebKit/{BUNDLE}", f"{HOME}/Library/HTTPStorages/{BUNDLE}",
                 f"{HOME}/Library/HTTPStorages/{BUNDLE}.binarycookies", f"{HOME}/Library/Caches/{BUNDLE}"]:
        subprocess.run(["rm", "-rf", path])
    shutil.rmtree(work, ignore_errors=True)


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        port = self.server.server_port
        head = []
        if self.path.startswith("/set"):
            mark = self.path.split("?", 1)[1]
            head = [("Set-Cookie", f"srv={mark}; Max-Age=86400; Path=/; HttpOnly")]
            # The consent-style frame: another site (localhost against
            # 127.0.0.1) sets its own cookie from inside the page.
            body = f"""<!doctype html><title>set</title><script>
document.cookie = 'js={mark}; max-age=86400; path=/';
localStorage.setItem('ls', '{mark}');
addEventListener('message', e => window.framed = e.data);
</script><iframe src="http://localhost:{port}/frame?{mark}"></iframe>"""
        elif self.path.startswith("/frame"):
            mark = self.path.split("?", 1)[1]
            head = [("Set-Cookie", f"consent={mark}; Max-Age=86400; Path=/; SameSite=None; Secure"),
                    ("Set-Cookie", f"consentlax={mark}; Max-Age=86400; Path=/")]
            body = "<script>parent.postMessage('framed', '*')</script>"
        else:
            sent = (self.headers.get("Cookie") or "").replace('"', "")
            body = f"""<!doctype html><title>check</title><script>
window.got = {{sent: "{sent}", read: document.cookie, ls: localStorage.getItem('ls') || ''}};
</script>"""
        self.send_response(200); self.send_header("Content-Type", "text/html")
        for k, v in head: self.send_header(k, v)
        self.end_headers(); self.wfile.write(body.encode())

    def log_message(self, *a): pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H); threading.Thread(target=srv.serve_forever, daemon=True).start()
PORT = srv.server_port


def wait(id, js, within=10):
    until = time.time() + within
    while time.time() < until:
        try:
            got = sv.ev(id, js)
        except RuntimeError:
            # Not loaded yet: the page before it has no such thing.
            got = None
        if got: return got
        time.sleep(0.2)
    return None


def check(host="127.0.0.1"):
    id = sv.cmd({"do": "open", "url": f"http://{host}:{PORT}/check"})["id"]
    return wait(id, "window.got") or {}


def case(t, mark, after, **prefs):
    tag = f"{STORE}{mark}: "
    sv.setup(**prefs)
    if STORE: forget_copy_store()
    sv.launch()
    id = sv.cmd({"do": "open", "url": f"http://127.0.0.1:{PORT}/set?{mark}"})["id"]
    t.ok(tag + "page set everything", wait(id, "localStorage.getItem('ls')") == mark)
    wait(id, "window.framed")
    before = check()
    t.ok(tag + "before quitting, sent both cookies", f"srv={mark}" in before.get("sent", "") and f"js={mark}" in before.get("sent", ""), before)
    time.sleep(after)
    sv.quit(); sv.launch()
    got = check()
    t.ok(tag + "after relaunch, the server's HttpOnly cookie is sent", f"srv={mark}" in got.get("sent", ""), got)
    t.ok(tag + "after relaunch, the script's cookie is sent", f"js={mark}" in got.get("sent", ""), got)
    t.ok(tag + "after relaunch, local storage is there", got.get("ls") == mark, got)
    framed = check("localhost")
    if prefs.get("sites.keep"):
        t.ok(tag + "after relaunch, the framed site's cookie is sent", f"consentlax={mark}" in framed.get("sent", ""), framed)
    print(f"  ..   {tag}framed site sees {framed.get('sent')!r}")


STORE = ""


def forget_copy_store():
    for path in [f"{HOME}/Library/WebKit/{BUNDLE}", f"{HOME}/Library/HTTPStorages/{BUNDLE}",
                 f"{HOME}/Library/HTTPStorages/{BUNDLE}.binarycookies"]:
        subprocess.run(["rm", "-rf", path])


def main():
    global STORE
    t = sv.T()
    built = sv.APP
    try:
        for store in ["", "default store, "]:
            STORE = store
            sv.APP = own_copy() if store else built
            case(t, "fast", 0)
            case(t, "slow", 10)
            case(t, "fastkeep", 0, **{"sites.keep": True})
            case(t, "slowkeep", 10, **{"sites.keep": True})
            sv.finish()
    finally:
        t.done(); sv.finish(); forget_copy()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
