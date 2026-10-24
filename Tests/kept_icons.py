"""What the icon index keeps, and what it lets go, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/kept_icons.py`. A page is
kept by its path alone, never its query; an address forgotten from History
takes its page with it, and its icon file once nothing wears it; a private
tab's pages are its own, and go when the last private tab closes; an icon
that never answers is asked twice and then left alone for a minute; and a
page that declares a dozen icons is asked for six at most.
"""
import hashlib
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402
from arc_icons import png  # noqa: E402
from sub_path_icons import bluish, reddish  # noqa: E402

sv.use("kept-icons")

COLOURS = {"sonarr": (220, 40, 40), "radarr": (40, 90, 220)}
hits = []
lock = threading.Lock()


class Apps(BaseHTTPRequestHandler):
    def do_GET(self):
        with lock:
            hits.append((time.monotonic(), self.path))
        app, _, rest = self.path.partition("?")[0].strip("/").partition("/")
        if app in COLOURS and rest == "icon.png":
            self.reply(png(COLOURS[app], side=32), "image/png")
        elif app in COLOURS and rest == "login":
            self.reply(f"<!doctype html><title>{app}</title><link rel=icon href='/{app}/icon.png'>".encode(), "text/html")
        elif app in COLOURS:
            self.reply(f"<!doctype html><title>{app} {rest}</title>".encode(), "text/html")
        elif app == "mute" and rest == "icon.png":
            # No answer at all: the connection closes with nothing on it.
            self.close_connection = True
        elif app == "mute":
            self.reply(b"<!doctype html><title>mute</title><link rel=icon href='/mute/icon.png'>", "text/html")
        elif app == "many" and rest == "login":
            links = "".join(f"<link rel=icon href='/many/i{n}.png'>" for n in range(12))
            self.reply(f"<!doctype html><title>many</title>{links}".encode(), "text/html")
        else:
            self.send_response(404)
            self.end_headers()

    def reply(self, body, kind):
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a): pass


def serve():
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Apps)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, f"http://127.0.0.1:{srv.server_port}", f"127.0.0.1:{srv.server_port}"


def icon(tab_id, window=None):
    req = {"do": "tabs", **({"window": window} if window else {})}
    for tab in sv.cmd(req).get("tabs", []):
        if tab["id"] == tab_id: return tab.get("icon", "")
    return ""


def wait(tab_id, want, window=None):
    for _ in range(50):
        if want(icon(tab_id, window)): break
        time.sleep(0.2)
    return icon(tab_id, window)


def index():
    try:
        return json.loads(Path(f"{sv.SUPPORT}/icons/pages.json").read_text())
    except (OSError, ValueError):
        return {}


def settle(site, want):
    for _ in range(20):
        if want(index().get(site, {})): break
        time.sleep(0.25)
    return index().get(site, {})


def until(cond):
    for _ in range(40):
        if cond(): break
        time.sleep(0.25)
    return cond()


def ident(url): return hashlib.sha256(url.encode()).hexdigest()[:32]
def letter(c): return c == ""
def open_(url, **f): return sv.cmd({"do": "open", "url": url, **f})["id"]
def windows(action, **f): return sv.cmd({"do": "windows", "action": action, **f})["windows"]


def count(prefix):
    with lock:
        return sum(1 for _, path in hits if path.startswith(prefix))


def asks(path):
    """How many times the app asked for `path`. URLSession tries a dropped
    connection three times by itself, within a few milliseconds: hits more
    than a second apart are the app asking again."""
    with lock:
        whens = sorted(when for when, p in hits if p == path)
    return sum(1 for i, when in enumerate(whens) if i == 0 or when - whens[i - 1] > 1)


def main():
    srv, base, site = serve()
    # A site of its own for the private tabs, with nothing of it kept.
    apart, base2, site2 = serve()
    t = sv.T()
    try:
        sv.setup()
        # An index from a build that kept queries in its keys.
        folder = Path(f"{sv.SUPPORT}/icons")
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "pages.json").write_text(json.dumps({site: {
            "/radarr/login?old=1": {"light": "0" * 32, "seen": 5},
            "/radarr/login?older=1": {"light": "1" * 32, "seen": 3},
        }}))
        sv.launch()

        # 1. A page is its path.
        queried = open_(f"{base}/sonarr/login?x=1")
        t.ok("a page with a query wears its icon", reddish(wait(queried, reddish)), icon(queried))
        kept = settle(site, lambda p: "/radarr/login" in p and "/sonarr/login" in p)
        t.ok("an index kept with queries is folded into paths on load, the latest seen kept",
             kept.get("/radarr/login", {}).get("light") == "0" * 32 and not any("?" in k for k in kept), kept)
        t.ok("the page is kept by its path, without the query", "/sonarr/login" in kept, kept)
        plain = open_(f"{base}/sonarr/login")
        t.ok("the same page without the query wears the same icon", reddish(wait(plain, reddish)), icon(plain))
        time.sleep(1.5)
        kept = index().get(site, {})
        t.ok("with and without the query, one entry", [k for k in kept if k.startswith("/sonarr/")] == ["/sonarr/login"], kept)

        # 2. Forgotten from History, the page and its icon go.
        file = folder / f"{ident(f'{base}/sonarr/icon.png')}.png"
        t.ok("the icon is on disk while a page wears it", until(file.exists), file)
        address = f"{base}/sonarr/login?x=1"
        sv.cmd({"do": "history", "take": address})
        listed = sv.cmd({"do": "history", "forget": address})["history"]
        t.ok("the address left History", address not in listed, listed)
        kept = settle(site, lambda p: "/sonarr/login" not in p)
        t.ok("forgetting the address drops its page from the index", "/sonarr/login" not in kept, kept)
        t.ok("and its icon file, once no page wears it", until(lambda: not file.exists()), file)

        # 3. A private tab's pages are its own, and go with the last private tab.
        shy = open_(f"{base2}/radarr/login", private=True)
        t.ok("a private tab fetches its page's icon", bluish(wait(shy, bluish)), icon(shy))
        plain2 = open_(f"{base2}/radarr/calendar")
        time.sleep(2.5)
        t.ok("a normal tab on the app's undeclared page shows a letter, not the private tab's icon",
             letter(icon(plain2)), icon(plain2))
        shy2 = open_(f"{base2}/radarr/calendar", private=True)
        t.ok("another private tab on that page borrows the private one's", bluish(wait(shy2, bluish)), icon(shy2))
        sv.cmd({"do": "close", "id": shy})
        shy3 = open_(f"{base2}/radarr/calendar", private=True)
        t.ok("one private tab closed with another open: what it saw stays", bluish(wait(shy3, bluish)), icon(shy3))
        sv.cmd({"do": "close", "id": shy2})
        sv.cmd({"do": "close", "id": shy3})
        shy4 = open_(f"{base2}/radarr/calendar", private=True)
        time.sleep(2)
        t.ok("the last private tab closed with ⌘W: a new one shows a letter", letter(icon(shy4)), icon(shy4))
        sv.cmd({"do": "close", "id": shy4})
        # The same through a window closing with the private tab in it.
        windows("new")
        far = open_(f"{base2}/radarr/login", window=2, private=True)
        t.ok("a private tab in a second window fetches its icon", bluish(wait(far, bluish, window=2)), icon(far, 2))
        near = open_(f"{base2}/radarr/calendar", window=1, private=True)
        t.ok("a private tab in the first window sees it", bluish(wait(near, bluish, window=1)), icon(near, 1))
        sv.cmd({"do": "close", "id": near, "window": 1})
        windows("close", n=2)
        time.sleep(0.5)
        shy5 = open_(f"{base2}/radarr/calendar", window=1, private=True)
        time.sleep(2)
        t.ok("the window with the last private tab closed: a new one shows a letter", letter(icon(shy5, 1)), icon(shy5, 1))

        # 4. An icon that never answers is asked twice, then left alone.
        open_(f"{base}/mute/login")
        until(lambda: asks("/mute/icon.png") >= 2)
        time.sleep(1.5)
        t.ok("an icon that drops the connection is asked once, and once more after 3 s",
             asks("/mute/icon.png") == 2, asks("/mute/icon.png"))
        open_(f"{base}/mute/other")
        time.sleep(4.5)
        t.ok("another page of the app within the minute asks no more", asks("/mute/icon.png") == 2, asks("/mute/icon.png"))

        # 5. A dozen declared icons: six requests at most.
        before = count("/many/i"), count("/favicon.ico")
        open_(f"{base}/many/login")
        time.sleep(3)
        asked = count("/many/i") - before[0]
        root = count("/favicon.ico") - before[1]
        t.ok("of a dozen declared icons, five are tried", 1 <= asked <= 5, asked)
        t.ok("six requests at most, favicon.ico included", asked + root <= 6, (asked, root))

        t.ok("nothing a private tab saw is in the index", site2 not in index(), list(index()))
    finally:
        t.done()
        sv.finish()
        srv.shutdown()
        apart.shutdown()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
