#!/usr/bin/env python3
"""Suggestions under a site put in the field with Tab (SiteSearch.swift), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/site_search_suggestions.py`.
The app starts hidden in a world of its own, is driven through ./bench's
socket, and is quit; its world is removed afterwards.

What you searched a site for before comes from the window's history, put
in as an import would (a bench tab's visits never enter it), and nothing is
sent for it. Your engine's suggestions come only when the site in the field
is your engine; the test world's `suggest.testURL` points that question at
a fake engine on this Mac, which records every question it gets.
"""
import json
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bld-sitesug")
asked = []
lock = threading.Lock()


class Engine(BaseHTTPRequestHandler):
    def do_GET(self):
        q = parse_qs(urlparse(self.path).query).get("q", [""])[0]
        with lock:
            asked.append(q)
        body = json.dumps([q, [f"{q} one", f"{q} two"]]).encode()
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *a):
        pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), Engine)
threading.Thread(target=srv.serve_forever, daemon=True).start()
FAKE = f"http://127.0.0.1:{srv.server_port}/sug?q=%s"


def field(text, typed=False):
    return sv.cmd({"do": "field", "text": text, "type": typed})


def sug(action="state", **f):
    return sv.cmd({"do": "suggest", "action": action, **f})


def site(action="state", **f):
    return sv.cmd({"do": "sitesearch", "action": action, **f})


def rows(s):
    return [(o[0], o[1]) for o in s["offers"]]


def count():
    with lock:
        return len(asked)


def chip(name, words=None):
    """The field emptied, the site's name typed, Tab, then the words."""
    sug("esc")
    sug("esc")
    field(name)
    took = site("tab")["took"]
    if words:
        field(words, typed=True)
    time.sleep(0.9)
    return took, sug()


def main():
    t = sv.T()
    try:
        sv.setup()
        for k, v in [("suggest.testURL", FAKE), ("search.engine", "google")]:
            subprocess.run(["defaults", "write", sv.SUITE, k, "-string", v])
        # A site shortcut, "rd words", to the same Reddit search.
        shortcut = json.dumps([{"id": "6F1C2D3E-0000-4000-8000-000000000001", "keyword": "rd",
                                "template": "https://www.reddit.com/search/?q=%s"}]).encode().hex()
        subprocess.run(["defaults", "write", sv.SUITE, "search.keywords", "-data", shortcut])
        sv.launch()
        sv.page("start")
        for address in ["https://www.reddit.com/search/?q=naruto%20ending%20explained",
                        "https://www.reddit.com/search/?q=naruto+vs+one+piece",
                        "https://www.reddit.com/r/Naruto/search/?q=naruto%20art",
                        "https://www.reddit.com/search/?q=coffee",
                        "https://www.google.com/search?q=naruto&sca_esv=1"]:
            sv.cmd({"do": "history", "take": address})
            time.sleep(0.2)

        # Reddit: what you searched it for, and nothing sent anywhere.
        sug(on=True)
        took, s = chip("red", "naruto")
        t.ok("Tab puts Reddit in the field", took, s)
        t.ok("Reddit: its search first, then what you searched it for, newest first",
             rows(s) == [("naruto", "search"), ("naruto vs one piece", "searched"), ("naruto ending explained", "searched")],
             rows(s))
        t.ok("Reddit: a subreddit's own search isn't Reddit's", "naruto art" not in [r[0] for r in rows(s)], rows(s))
        t.ok("Reddit: nothing asked of the engine", count() == 0, asked)

        # Before a word is typed: the last few searched there.
        took, s = chip("red")
        t.ok("Reddit, nothing typed: the last searches, newest first",
             [r for r in rows(s)] == [("coffee", "searched"), ("naruto vs one piece", "searched"),
                                       ("naruto ending explained", "searched")], rows(s))

        # Taking one searches Reddit for it.
        took, s = chip("red", "naruto")
        index = [r[0] for r in rows(s)].index("naruto vs one piece")
        s = sug("take", index=index)
        where = s["address"] + " " + s["pending"]
        t.ok("taking a past search searches Reddit for it", "reddit.com/search/" in where and "naruto" in where, where)

        # A shortcut is the chip typed out: the same past searches, the
        # shortcut kept in front so a row walked to reads as typed.
        sug("esc")
        sug("esc")
        field("rd naruto", typed=True)
        time.sleep(0.9)
        s = sug()
        t.ok("shortcut: Reddit's search, then what you searched it for",
             rows(s)[-2:] == [("rd naruto vs one piece", "searched"), ("rd naruto ending explained", "searched")], rows(s))
        t.ok("shortcut: a past search goes to Reddit's search for its words",
             any(o[1] == "searched" and o[2] == "https://www.reddit.com/search/?q=naruto%20vs%20one%20piece" for o in s["offers"]),
             s["offers"])

        # Google in the field, and Google is your engine: its suggestions.
        took, s = chip("google", "naruto")
        t.ok("Google in the field: the engine is asked", asked[-1:] == ["naruto"], asked)
        t.ok("Google in the field: its suggestions, searched on Google",
             [r for r in s["offers"] if r[1] == "suggested"] ==
             [["naruto one", "suggested", "https://www.google.com/search?q=naruto%20one"],
              ["naruto two", "suggested", "https://www.google.com/search?q=naruto%20two"]], s["offers"])

        # The site taken out of the field: the engine's own list again.
        site("delete")  # the words
        for _ in range(len("naruto")):
            site("delete")
        s = site("delete")
        t.ok("⌫ takes Google out of the field", s["chip"] == "", s)

        # No site in the field: a search page from history reads as the
        # search it was, and still goes to that page.
        sug("esc")
        sug("esc")
        field("naruto", typed=True)
        time.sleep(0.9)
        s = sug()
        searched = [o for o in s["offers"] if o[1] == "searched"]
        # (Taking a row above really opened Reddit, which may have sent the
        # page through its check first, ?js_challenge=1&…&q=…: that visit
        # is in history too, and reads the same.)
        t.ok("plain field: Reddit search pages read as their words",
             "naruto vs one piece" in [o[0] for o in searched]
             and set(o[0] for o in searched) <= {"naruto vs one piece", "naruto ending explained"}, s["offers"])
        t.ok("plain field: such a row goes to the page it was",
             all(o[2].startswith("https://www.reddit.com/search/?") for o in searched), searched)
        t.ok("plain field: no raw search addresses left", not any("/search" in o[0] for o in s["offers"]), rows(s))
        t.ok("plain field: your engine's page for exactly what was typed isn't a second row",
             [r for r in rows(s) if r[0] == "naruto"] == [("naruto", "search")], rows(s))
        # An address being typed still finishes as one.
        sug("esc")
        sug("esc")
        field("reddit.com/se", typed=True)
        time.sleep(0.5)
        s = sug()
        t.ok("an address still gets its grey ending", s["ending"].startswith("arch/"), (s["ending"], rows(s)))

        # Off is off.
        sug(on=False)
        before = count()
        took, s = chip("google", "ramen")
        t.ok("switch off: nothing asked with Google in the field", count() == before, asked[before:])
        t.ok("switch off: no suggested rows", all(r[1] != "suggested" for r in rows(s)), rows(s))
        sug(on=True)

        # (Google in the field when your engine is another: EngineSuggestTests.)
        # Never in a private tab: neither past searches nor a question.
        sug("esc")
        sug("esc")
        sv.sp("private")
        time.sleep(0.5)
        before = count()
        took, s = chip("red", "naruto")
        t.ok("private tab: it is one", s["shy"] is True, s)
        t.ok("private tab: no past searches", all(r[1] != "searched" for r in rows(s)), rows(s))
        took, s = chip("google", "naruto")
        t.ok("private tab: nothing asked with Google in the field", count() == before, asked[before:])
    finally:
        t.done()
        sv.finish()
        srv.shutdown()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
