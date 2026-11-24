#!/usr/bin/env python3
"""A page that never arrived keeps the address it failed at (idea 1080).

Build first (`./build.sh`), then `python3 Tests/failed_url_field.py`. The app
starts hidden in a world of its own (failed-url-<checkout>, see
split_view.use), is driven through ./bench's socket, and is quit; its world
is removed afterwards. Nothing here makes, shows or brings forward a window,
and nothing touches the Mac's pasteboard: Copy Address is read from a
pasteboard of the bench's own (bench copyaddress).

The case is an OAuth sign-in handing a CLI's code back to
http://localhost:<port>/callback, with nothing listening there. From a sign-in
page served here, a link, a form, a 302 and a script's redirect each go to
http://localhost:<closed port>/cb?code=abc&state=xyz. Each time the
tab must say "refused", and its address, the field ⌘L raises and Copy Address
must all be that URL, query and all. Back goes to the sign-in page. Reload
tries the failed URL again: a server started on its port then answers it.
"""
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("failed-url")
REFUSED = "The site refused the connection."


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


# A port nothing listens on, as a CLI's callback that has gone away.
CLOSED = free_port()
FAIL = f"http://localhost:{CLOSED}/cb?code=abc&state=xyz"
# Port 9 is one WebKit refuses outright (a restricted port): a page's link or
# script to it never starts a load, in Safari too, so there is nothing to say.
# A server's 302 there does start one, and fails.
PORT9 = "http://localhost:9/cb?code=abc&state=xyz"
LATER = free_port()
LATER_URL = f"http://localhost:{LATER}/callback?code=c0de&state=s7"


class Pages(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in ("/302", "/302-9"):
            self.send_response(302)
            self.send_header("Location", PORT9 if self.path == "/302-9" else FAIL)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path == "/js":
            body = f"<!doctype html><title>js</title><script>setTimeout(() => location.replace({FAIL!r}), 300)</script>"
        else:
            body = (f"<!doctype html><title>signin</title><p>Sign in"
                    f"<a id=link href='{FAIL}'>continue</a>"
                    f"<a id=later href='{LATER_URL}'>later</a>"
                    f"<form id=form action='http://localhost:{CLOSED}/cb' method=get>"
                    f"<input name=code value=abc><input name=state value=xyz></form>")
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


class Callback(BaseHTTPRequestHandler):
    def do_GET(self):
        data = b"<!doctype html><title>signed in</title><p>You can close this tab."
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
threading.Thread(target=srv.serve_forever, daemon=True).start()
SITE = f"http://localhost:{srv.server_port}"


def tab(id):
    found = next(t for t in sv.cmd({"do": "tabs"})["tabs"] if t["id"] == id)
    found.setdefault("failure", "(not reported)")
    return found


def until(test, within=10):
    end = time.time() + within
    while time.time() < end:
        got = test()
        if got:
            return got
        time.sleep(0.2)
    return test()


def field():
    """What ⌘L puts in the field, then put away with Escape."""
    sv.cmd({"do": "press", "code": 37, "chars": "l", "mods": ["cmd"], "letgo": True})
    time.sleep(0.6)
    s = sv.cmd({"do": "suggest"})
    typed = s["typed"] if s["editing"] else None
    sv.cmd({"do": "press", "code": 53, "chars": "\x1b", "mods": []})
    time.sleep(0.4)
    return typed


def copied():
    try:
        return sv.cmd({"do": "copyaddress"}).get("copied")
    except RuntimeError as error:
        return f"(no copyaddress: {error})"


def signin(id):
    sv.cmd({"do": "go", "id": id, "url": f"{SITE}/signin"})
    return until(lambda: tab(id)["title"] == "signin" and not tab(id)["loading"])


def failed_at(t, id, how, url=FAIL, said=REFUSED):
    got = until(lambda: tab(id)["failure"] == said and tab(id))
    t.ok(f"{how}: says {said!r}", bool(got), tab(id))
    now = tab(id)
    t.ok(f"{how}: the tab's address is the failed URL", now["url"] == url, now["url"])
    typed = field()
    t.ok(f"{how}: ⌘L's field holds it, query and all", typed == url, typed)
    board = copied()
    t.ok(f"{how}: Copy Address copies it", board == url, board)


def main():
    t = sv.T()
    try:
        sv.setup()
        sv.launch()
        id = sv.sp("open", url=f"{SITE}/signin")["resultID"]
        sv.sp("select", id=id)
        until(lambda: tab(id)["title"] == "signin")
        t.ok("the sign-in page is up, no failure", tab(id)["failure"] == "" and tab(id)["url"] == f"{SITE}/signin", tab(id))
        t.ok("before: Copy Address is the sign-in page", copied() == f"{SITE}/signin")

        # A link.
        sv.ev(id, "document.getElementById('link').click()")
        failed_at(t, id, "link")
        # Back: the sign-in page that was under it, with its own address.
        sv.cmd({"do": "press", "code": 33, "chars": "[", "mods": ["cmd"], "letgo": True})
        back = until(lambda: tab(id)["failure"] == "" and tab(id))
        t.ok("back: the failure is gone", bool(back), tab(id))
        now = tab(id)
        t.ok("back: the address is the sign-in page's", now["url"] == f"{SITE}/signin", now)
        t.ok("back: Copy Address is the sign-in page's", copied() == f"{SITE}/signin")
        t.ok("back: still the sign-in page on screen", sv.ev(id, "document.title") == "signin")

        # A form.
        sv.ev(id, "document.getElementById('form').submit()")
        failed_at(t, id, "form")

        # A 302 from the server.
        sv.cmd({"do": "go", "id": id, "url": f"{SITE}/302"})
        failed_at(t, id, "302")

        # A 302 to port 9, which WebKit won't connect to: a failure all the same.
        sv.cmd({"do": "go", "id": id, "url": f"{SITE}/302-9"})
        failed_at(t, id, "302 to port 9", PORT9, "The page didn't load.")

        # A script's redirect, after its page came in.
        sv.cmd({"do": "go", "id": id, "url": f"{SITE}/js"})
        failed_at(t, id, "js redirect")

        # A new address over a failure: the field follows the new page.
        signin(id)
        t.ok("a page after a failure: its own address", tab(id)["url"] == f"{SITE}/signin" and tab(id)["failure"] == "", tab(id))

        # Reload tries the failed URL again; once something listens there, it
        # arrives, its address the one that failed.
        sv.ev(id, "document.getElementById('later').click()")
        failed_at(t, id, "later", LATER_URL)
        cb = ThreadingHTTPServer(("127.0.0.1", LATER), Callback)
        threading.Thread(target=cb.serve_forever, daemon=True).start()
        sv.cmd({"do": "press", "code": 15, "chars": "r", "mods": ["cmd"], "letgo": True})
        came = until(lambda: tab(id)["title"] == "signed in" and tab(id))
        now = tab(id)
        t.ok("reload: the failed URL is tried again and arrives", bool(came), now)
        t.ok("reload: no failure left", now["failure"] == "", now)
        t.ok("reload: the address is the callback's", now["url"] == LATER_URL, now["url"])
        cb.shutdown()
        # Back from there: the sign-in page.
        sv.cmd({"do": "press", "code": 33, "chars": "[", "mods": ["cmd"], "letgo": True})
        t.ok("back after the retry: the sign-in page", bool(until(lambda: tab(id)["title"] == "signin" and tab(id)["url"] == f"{SITE}/signin")), tab(id))
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
