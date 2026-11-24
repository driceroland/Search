#!/usr/bin/env python3
"""Suggestions from your search engine (idea 347, EngineSuggest.swift), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/engine_suggestions.py`. The
app starts hidden in a world of its own (bld-sug-<checkout>, see
split_view.use), is driven through ./bench's socket, and is quit; its world
is removed afterwards. Nothing here makes, shows or brings forward a window.

No real engine is asked: the custom engine's searches, and the suggestions
address given to it in Settings, point at a fake engine on this Mac (http on
loopback is honoured only in a test run). It records every question, with the
headers it came with.
"""
import json
import statistics
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bld-sug")
asked = []          # (q, headers) for every question the fake engine got
lock = threading.Lock()


class Engine(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)
        q = parse_qs(url.query).get("q", [""])[0]
        if url.path == "/sug":
            with lock:
                asked.append((q, {k.lower(): v for k, v in self.headers.items()}))
            if q == "slowq":
                time.sleep(1.6)
            if q == "aa":
                time.sleep(0.7)   # slow, but inside the 0.8 s the field waits
                words = ["aa STALE"]
            else:
                words = [q] + [f"{q} {n}" for n in ["one", "two", "three", "four", "five", "six", "seven", "eight"]]
            body = json.dumps([q, words]).encode()
            kind = "application/json"
        else:
            # The custom engine's results page, and a page that leaves a cookie.
            body = f"<!doctype html><title>{url.path}</title><script>document.cookie='page=1; path=/'</script>{q}".encode()
            kind = "text/html"
        try:
            self.send_response(200)
            self.send_header("Content-Type", kind)
            self.send_header("Set-Cookie", "engine=tracked; Path=/; Max-Age=3600")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *a):
        pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), Engine)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"


def field(text, typed=False):
    return sv.cmd({"do": "field", "text": text, "type": typed})


def sug(action="state", **f):
    return sv.cmd({"do": "suggest", "action": action, **f})


def kinds(s):
    return [o[1] for o in s["offers"]]


def suggested(s):
    return [o[0] for o in s["offers"] if o[1] == "suggested"]


def count():
    with lock:
        return len(asked)


def main():
    t = sv.T()
    try:
        sv.setup()
        for k, v in [("search.engine", "custom"), ("search.custom", f"{BASE}/search?q=%s"),
                     ("search.customSuggest", f"{BASE}/sug?q=%s")]:
            subprocess.run(["defaults", "write", sv.SUITE, k, "-string", v])
        sv.launch()
        sv.page("start")

        # Off unless turned on: nothing leaves.
        s = sug()
        t.ok("off by default", s["on"] is False, s)
        field("coffee shop", typed=True)
        time.sleep(0.9)
        s = sug()
        t.ok("off: nothing sent", count() == 0, asked)
        t.ok("off: no engine rows", "suggested" not in kinds(s), s["offers"])
        sug("esc")

        # On: one question once typing pauses, six rows after the field's own.
        sug(on=True)
        field("coffee", typed=True)
        time.sleep(0.9)
        s = sug()
        with lock:
            qs = [q for q, _ in asked]
        t.ok("on: one question for six keys typed quickly (debounce)", qs == ["coffee"], qs)
        t.ok("on: six engine rows", suggested(s) == [f"coffee {n}" for n in ["one", "two", "three", "four", "five", "six"]], s["offers"])
        first = kinds(s).index("suggested") if "suggested" in kinds(s) else -1
        t.ok("engine rows come after the field's own rows", first > 0 and all(k == "suggested" for k in kinds(s)[first:])
             and "search" in kinds(s)[:first], kinds(s))
        t.ok("what was typed is not repeated as a row", "coffee" not in suggested(s), suggested(s))
        with lock:
            _, headers = asked[-1]
        t.ok("no cookie sent", "cookie" not in headers, headers)
        t.ok("no referrer sent", "referer" not in headers, headers)

        # Choosing one searches it.
        index = first + 1
        s = sug("take", index=index)
        where = s["address"] + " " + s["pending"]
        t.ok("clicking a row searches it", "/search?q=coffee%20two" in where, where)

        # Walking to one and pressing Return does too, and the field shows it.
        field("coffee", typed=True)
        time.sleep(0.9)
        s = sug()
        first = kinds(s).index("suggested")
        for _ in range(first + 1):
            w = sug("walk", step=1)
        t.ok("walking onto a row puts its words in the field", w["completed"] == "coffee one", w.get("completed"))
        s = sug("go")
        where = s["address"] + " " + s["pending"]
        t.ok("Return on a row searches it", "/search?q=coffee%20one" in where, where)

        # The engine's cookie, and one a page on its host left in the
        # browser's own store, are never sent with a question.
        sv.sp("open", url=f"{BASE}/cookie-page")
        time.sleep(0.5)
        before = count()
        field("tea", typed=True)
        time.sleep(0.9)
        with lock:
            new = asked[before:]
        t.ok("a later question: sent", [q for q, _ in new] == ["tea"], [q for q, _ in new])
        t.ok("a later question: still no cookie, none of the page's either", all("cookie" not in h for _, h in new), new)
        sug("esc")

        # Nothing that looks like an address, a file, an email, a key or a paragraph.
        before = count()
        for text in ["https://example.com/private?token=1", "example.com", "localhost:3000", "192.168.1.1",
                     "/Users/drice/Documents/taxes.pdf", "~/Desktop/notes.txt", "drice@officecommun.com",
                     "gh" + "p_0000Fake1111Token2222Shape3333Only44", "hunter2hunter2x", "4111111111111111",
                     "javascript:alert(1)", "mailto:someone@example.com", "word " * 17]:
            field(text)
            time.sleep(0.45)
            s = sug()
            t.ok(f"not sent: {text[:40]!r}", count() == before and "suggested" not in kinds(s), (asked[before:], s["offers"]))
        sug("esc")

        # Cancel: an answer to what was typed before never lands on what is typed now.
        before = count()
        c0 = sug()["cancelled"]
        # The bench puts each text in half a second after it is asked to: "aab"
        # lands about 0.5 s after "aa", while the engine is still answering it.
        field("aa")
        field("aab")
        time.sleep(1.0)
        s = sug()
        with lock:
            qs = [q for q, _ in asked[before:]]
        t.ok("the slow question was asked", "aa" in qs, qs)
        t.ok("its stale answer never shows", "aa STALE" not in suggested(s), s["offers"])
        t.ok("the newer question answers", suggested(s)[:1] == ["aab one"], s["offers"])
        t.ok("the older question was let go of", s["cancelled"] > c0, (c0, s["cancelled"]))
        sug("esc")

        # Too slow: nothing, rather than rows arriving after the moment.
        s0 = sug()["tooSlow"]
        field("slowq")
        time.sleep(1.9)
        s = sug()
        t.ok("an engine slower than 0.8 s shows nothing", "suggested" not in kinds(s) and s["tooSlow"] > s0, (s["offers"], s["tooSlow"]))
        sug("esc")

        # Typing stays as quick with the switch on: the rest after each key,
        # off and on taken in turn, each typed over an answer already in
        # (so the engine's rows are in the list the keys rebuild).
        rests = {False: [], True: []}
        for round in range(4):
            for on in ([False, True] if round % 2 == 0 else [True, False]):
                sug(on=on)
                field("coffee", typed=True)
                time.sleep(0.6)
                rests[on] += [m[1] for m in field("coffee shop near", typed=True)["ms"]]
                time.sleep(0.4)
                sug("esc")
        rest_off, rest_on = statistics.median(rests[False]), statistics.median(rests[True])
        print(f"  ..  per key, median rest: off {rest_off:.2f} ms, on {rest_on:.2f} ms ({len(rests[True])} keys each)")
        t.ok("typing is not slowed (median per key within 2 ms of off)", rest_on <= rest_off + 2, (rest_off, rest_on))
        sug(on=True)

        # Never from a private tab.
        sv.sp("private")
        time.sleep(0.5)
        before = count()
        field("coffee", typed=True)
        time.sleep(0.9)
        s = sug()
        t.ok("private tab: it is one", s["shy"] is True, s)
        t.ok("private tab: nothing sent", count() == before, asked[before:])
        t.ok("private tab: no engine rows", "suggested" not in kinds(s), s["offers"])
    finally:
        t.done()
        sv.finish()
        srv.shutdown()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
