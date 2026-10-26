#!/usr/bin/env python3
"""Bookmarks in the address field (idea 417), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/bookmark_offers.py`. The app
starts hidden in a world of its own (bld-marks-<checkout>, see
split_view.use), is driven through ./bench's socket, and is quit; its world
is removed afterwards. Nothing here makes, shows or brings forward a window
(a second profile's window is made hidden, and checked to be off screen).

Five thousand bookmarks come in as a Firefox export would bring them, then
words are typed into the field: the bookmarks come first, by name or address
and in any order of the words, then history, one row for a page that is
both, three places at most, and each key stays quick.
"""
import os
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bld-marks")


class Site(BaseHTTPRequestHandler):
    def do_GET(self):
        body = f"<!doctype html><title>{self.path.strip('/') or 'home'}</title>{self.path}".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), Site)
threading.Thread(target=srv.serve_forever, daemon=True).start()
SITE = f"http://127.0.0.1:{srv.server_port}"

# The ones looked for, among thousands of others.
WANTED = [
    ("Quarterly Taxes Checklist", "https://example.org/x/a1"),
    ("The Rust Reference", "https://doc.rust-lang.org/reference/"),
    ("Visited And Kept", f"{SITE}/kept"),
    ("Zebra one", "https://zebra-one.example/"),
    ("Zebra two", "https://zebra-two.example/"),
    ("Zebra three", "https://zebra-three.example/"),
    ("Zebra four", "https://zebra-four.example/"),
]


def export(path, filler=5000):
    """A Netscape bookmarks file, as Firefox's Export Bookmarks to HTML writes it."""
    rows = [f'<DT><A HREF="{url}" ADD_DATE="1700000000">{title}</A>' for title, url in WANTED]
    rows += [f'<DT><A HREF="https://site{n}.example.com/page/{n}" ADD_DATE="1700000000">Filler page number {n}</A>'
             for n in range(filler - len(WANTED))]
    folder = "\n".join(rows)
    Path(path).write_text(f"""<!DOCTYPE NETSCAPE-Bookmark-file-1>
<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
<TITLE>Bookmarks</TITLE>
<H1>Bookmarks Menu</H1>
<DL><p>
<DT><H3>Imported</H3>
<DL><p>
{folder}
</DL><p>
</DL>
""")


def c(req, window=None):
    if window:
        req = {**req, "window": window}
    return sv.cmd(req)


def typed(text, window=None):
    """Typed a key at a time; the offers and the grey ending after the last key."""
    f = c({"do": "field", "text": text, "type": True}, window)
    time.sleep(0.3)
    s = c({"do": "suggest"}, window)
    c({"do": "suggest", "action": "esc"}, window)
    time.sleep(0.2)
    return f, s


def saved(within=5):
    """When the bookmarks file was last written, once there is one."""
    end = time.time() + within
    while True:
        found = sorted(Path(sv.SUPPORT).rglob("bookmarks*.json"))
        if found or time.time() > end:
            return found[0].stat().st_mtime if found else None
        time.sleep(0.2)


def places(s):
    return [(o[1], o[2]) for o in s["offers"] if o[1] not in ("search", "suggested", "command")]


def main():
    t = sv.T()
    folder = tempfile.mkdtemp()
    file = os.path.join(folder, "bookmarks.html")
    export(file)
    try:
        sv.setup()
        sv.launch()
        # Where you have been: one page that is also bookmarked, one that isn't.
        for path in ["kept", "visited-only"]:
            sv.sp("open", url=f"{SITE}/{path}")
            time.sleep(1.0)

        took = c({"do": "import-file", "path": file})
        t.ok("five thousand bookmarks came in", took.get("total") == 5000, {k: took.get(k) for k in ["said", "bookmarks", "total"]})
        before = saved()
        t.ok("and were saved", before is not None, before)

        # By name, the words in any order.
        _, s = typed("checklist quarterly")
        t.ok("by name, words in any order", places(s)[:1] == [("bookmark", "https://example.org/x/a1")], s["offers"])

        # By address: first, and the field finishes towards it.
        _, s = typed("doc.rust")
        t.ok("by address, first", places(s)[:1] == [("bookmark", "https://doc.rust-lang.org/reference/")], s["offers"])
        t.ok("the grey ending finishes towards it", s["ending"] == "-lang.org/reference/", s["ending"])

        # Bookmarks first, then history; a page that is both is one row, the bookmark's.
        _, s = typed("127.0.0.1")
        p = places(s)
        t.ok("bookmarks before history", p and p[0] == ("bookmark", f"{SITE}/kept"), s["offers"])
        t.ok("a page both kept and visited is one row", sum(1 for _, u in p if u.rstrip("/") == f"{SITE}/kept") == 1, p)
        t.ok("history still offered after", ("visited", f"{SITE}/visited-only") in p, p)

        # Three places at most, one kept for history when it has one.
        _, s = typed("zebra")
        p = places(s)
        t.ok("three places at most", len(p) == 3 and all(k == "bookmark" for k, _ in p), p)
        _, s = typed("ze")
        t.ok("two letters are enough", any(k == "bookmark" for k, _ in places(s)), s["offers"])
        _, s = typed("z")
        t.ok("one letter offers no bookmark", not any(k == "bookmark" for k, _ in places(s)), s["offers"])

        # Each key quick, with five thousand to look through.
        f, s = typed("filler page number 4321")
        each = [m[0] if isinstance(m, list) else m for m in f.get("ms", [])]
        mid = statistics.median(each) if each else None
        print(f"       per key, ms: median {mid}, slowest {max(each) if each else None}")
        t.ok("each key stays quick (median under 25 ms)", mid is not None and mid < 25, each)
        t.ok("the right one among thousands", places(s)[:1] == [("bookmark", "https://site4321.example.com/page/4321")], s["offers"])

        # A private tab finds them too, and writes nothing.
        sv.sp("private")
        time.sleep(0.8)
        _, s = typed("quarterly taxes")
        t.ok("private: bookmarks offered", ("bookmark", "https://example.org/x/a1") in places(s), s["offers"])
        t.ok("private: nothing written", saved() == before, (before, saved()))

        # Another profile's window offers none of this profile's.
        c({"do": "profile", "action": "new", "name": "Other"})
        c({"do": "profile", "action": "window", "name": "Other"})
        time.sleep(1.5)
        shown = [w for w in c({"do": "windows"})["windows"] if w["shown"]]
        t.ok("no window on screen", not shown, shown)
        if shown:
            sv.quit()
            sys.exit("a window reached the screen: stopped")
        c({"do": "split", "action": "open", "url": f"{SITE}/other"}, 2)
        time.sleep(1.0)
        _, s = typed("quarterly taxes", 2)
        t.ok("another profile: none of these bookmarks", not any(k == "bookmark" for k, _ in places(s)), s["offers"])
    finally:
        t.done()
        sv.finish()
        subprocess.run(["rm", "-rf", folder])
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
