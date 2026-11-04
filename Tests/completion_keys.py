#!/usr/bin/env python3
"""A new tab's field keeps the keys while it completes an address, with Split
View on, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/completion_keys.py`. It uses
the split suite's harness: started hidden in a world of its own, no window
made or shown, everything removed afterwards. ⌘T and the letters after it are
pressed through the app's own event queue, as a hand's are.

Reported as: "web" typed in a new tab, the field finishing it as
web.whatsapp.com, and every key after that a beep with nothing typed. ⌘T's
request for the keys reached the field over the page being left as well as
the new tab's, and the old one answered last, as it went: the window was
left with the keys, and a window beeps at every key it is handed. The first
letters typed with ⌘T had already gone to the new field, so it looked like
the completion that stopped the typing.

The same is pressed again while the page left behind is still loading, and
asks for the caret in a box of its own once it has loaded (#796).
"""
import os
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("completion-keys")

CODES = {"b": 11, "w": 13, "e": 14, "x": 7, "y": 16, "z": 6}


class Site(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/slow":
            # Loads for two seconds, then puts the caret in its own box.
            time.sleep(2)
            body = b"<!doctype html><title>slow</title><input id=q autofocus><script>q.focus()</script>"
        else:
            body = f"<!doctype html><title>{self.path.strip('/')}</title>{self.path}".encode()
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


def marks(path):
    """Bookmarks beginning with "we", as in the report, and one that doesn't."""
    rows = "\n".join(
        f'<DT><A HREF="{u}" ADD_DATE="1700000000">{n}</A>'
        for n, u in [("Motto work", "https://wearemotto.com/work"), ("Noiced", "https://noiced.com/"),
                     ("Weather", "https://weather.example/")]
    )
    Path(path).write_text(f"<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<TITLE>Bookmarks</TITLE><H1>Bookmarks</H1>\n"
                          f"<DL><p>\n{rows}\n</DL><p>\n")


def press(ch, mods=()):
    code = 17 if ch == "t" else CODES[ch]
    return sv.cmd({"do": "press", "code": code, "chars": ch, "mods": list(mods)})


def look():
    """Where the keys are, what was typed, and what the field shows."""
    p = sv.cmd({"do": "probe"})
    s = sv.cmd({"do": "suggest"})
    return {"inField": p["responderIsAddress"], "responder": p["responder"],
            "typed": s["typed"], "ending": s["ending"], "field": p["fieldText"]}


def new_tab_and_type(text):
    """⌘T, then a key at a time: how the field stood after each."""
    press("t", ["cmd"])
    time.sleep(0.3)
    seen = []
    for ch in text:
        press(ch)
        time.sleep(0.1)
        seen.append((ch, look()))
    return seen


def kept(seen, text):
    """Every key landed in the field, and the last one left it holding them."""
    last = seen[-1][1]
    return all(f["inField"] for _, f in seen) and last["typed"] == text and last["field"].startswith(text)


def main():
    t = sv.T()
    folder = tempfile.mkdtemp()
    file = os.path.join(folder, "bookmarks.html")
    marks(file)
    try:
        sv.setup(sidebar=True, splitView=True)
        sv.launch()
        sv.cmd({"do": "history", "take": "https://web.whatsapp.com/", "count": 20})
        sv.cmd({"do": "import-file", "path": file})
        a = sv.page("a")

        seen = new_tab_and_type("web")
        t.ok("w, e, b: the field completes towards web.whatsapp.com",
             seen[-1][1]["field"] == "web.whatsapp.com" and seen[-1][1]["ending"] == ".whatsapp.com", seen[-1][1])
        for ch in "xyz":
            press(ch)
            time.sleep(0.1)
            seen.append((ch, look()))
        t.ok("and every key after it is typed into the field", kept(seen, "webxyz"),
             [(ch, f["inField"], f["responder"], f["typed"]) for ch, f in seen])

        # A few more times: a race shows as a rate, not a failure.
        lost = []
        for i in range(4):
            sv.sp("select", id=a)
            time.sleep(0.4)
            seen = new_tab_and_type("we")
            if not kept(seen, "we"):
                lost.append((i, seen[-1][1]))
        t.ok("⌘T from a page, then typing, 4 more times", not lost, lost[:2])

        # #796: a new tab while the page left is still loading, which then
        # asks for the caret in its own box.
        sv.sp("open", url=f"{SITE}/slow")
        time.sleep(0.3)
        press("t", ["cmd"])
        time.sleep(3)
        seen = []
        for ch in "we":
            press(ch)
            time.sleep(0.1)
            seen.append((ch, look()))
        t.ok("a page loading behind a new tab leaves its field the keys", kept(seen, "we"),
             [(ch, f["inField"], f["responder"], f["typed"]) for ch, f in seen])
    finally:
        t.done()
        sv.finish()
        subprocess.run(["rm", "-rf", folder])
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
