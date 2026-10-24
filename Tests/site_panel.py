#!/usr/bin/env python3
"""Websites in the side panel (idea 365), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/site_panel.py`. It runs in a
world of its own with split_view.py's harness: started hidden, everything
removed afterwards. Nothing is shown on any screen.

Off by default: nothing goes into the panel. On: a site goes there as a page
of the window's space, signed in where that space's tabs are (a cookie set in
the panel is the tabs' cookie), never a private tab's; the same site again
closes it; it keeps to the web; it goes into a tab of its own on request;
and after a switch to a space that starts afresh, it comes again signed in
as that space is.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler  # noqa: E402
import threading  # noqa: E402


class Slow(BaseHTTPRequestHandler):
    """A page that takes its time, on another host (localhost)."""
    def do_GET(self):
        time.sleep(3)
        body = b"<!doctype html><title>slow</title><p>slow"
        self.send_response(200); self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def log_message(self, *a): pass


slow = ThreadingHTTPServer(("127.0.0.1", 0), Slow)
threading.Thread(target=slow.serve_forever, daemon=True).start()
SLOW = f"http://localhost:{slow.server_port}/slow"

sv.use("bld-s107-sitepanel")
GAP = 8
WIDTH = 380


def panel(action="state", **f): return sv.cmd({"do": "sidepanel", "action": action, **f})


def peval(js): return panel("eval", js=js).get("value")


def wait(cond, within=6):
    until = time.time() + within
    while time.time() < until:
        if cond(): return True
        time.sleep(0.2)
    return cond()


def window():
    p = sv.cmd({"do": "probe"})
    w = next(w for w in p["windows"] if w["kind"] == "AppKitWindow")
    return w["frame"][2], w["frame"][3]


def urls(): return [x["url"] for x in sv.sp("state")["tabs"]]


def main():
    t = sv.T()
    try:
        # Off, as it is unless turned on.
        sv.setup(sidebar=True); sv.launch()
        sv.page("a")
        panel("site", url=f"{sv.BASE}/panel")
        t.ok("off: a site doesn't go into the panel", not panel()["shown"], panel())
        sv.quit()

        sv.setup(sidebar=True, **{"panel.sites": True})
        sv.launch()
        a = sv.page("a")
        panel("site", url=f"{sv.BASE}/panel")
        st = panel()
        t.ok("on: the site is in the panel", st["shown"] and st["content"]["kind"] == "site", st)
        wait(lambda: panel()["title"] == "panel")
        st = panel()
        t.ok("its page loads there", st["title"] == "panel" and st["page"].endswith("/panel"), st)
        t.ok("signed in as the space's tabs are: the space's own store", st["content"]["store"] is True and st["content"]["sameStore"] is True, st["content"])
        t.ok("no window opens from it without a click", st["opensWindows"] is False, st)
        t.ok("the Web Inspector reaches it as it reaches a tab", st["content"]["inspectable"] is True and st["content"]["developerExtras"] is True, st["content"])
        t.ok("its line names the page that arrived", st["content"]["line"] == "127.0.0.1 (not secure)" and st["content"]["arrived"].endswith("/panel"), st["content"])

        # No camera, microphone or screen for the panel's page.
        peval("window.__cam = 'held'; navigator.mediaDevices.getUserMedia({video: true, audio: true})"
              ".then(s => { window.__cam = 'granted'; s.getTracks().forEach(k => k.stop()) }, e => window.__cam = e.name); 1")
        peval("window.__screen = 'held'; navigator.mediaDevices.getDisplayMedia({video: true})"
              ".then(s => { window.__screen = 'granted'; s.getTracks().forEach(k => k.stop()) }, e => window.__screen = e.name); 1")
        wait(lambda: peval("window.__cam") != "held" and peval("window.__screen") != "held", within=4)
        cam, screen = peval("window.__cam"), peval("window.__screen")
        t.ok(f"camera and microphone are refused in the panel ({cam})", cam not in ("granted", None), cam)
        t.ok(f"screen sharing is refused in the panel ({screen})", screen not in ("granted", None), screen)

        # The line changes only once the next page arrives.
        peval(f"location.href = '{SLOW}'; 1"); time.sleep(1.0)
        sc = panel()["content"]
        t.ok("a page on its way: the line still names the one there", sc["line"].startswith("127.0.0.1") and sc["arrived"].endswith("/panel"), sc)
        wait(lambda: panel()["content"]["line"].startswith("localhost"), within=8)
        sc = panel()["content"]
        t.ok("once it arrives: the line names it", sc["line"].startswith("localhost") and sc["arrived"] == SLOW, sc)
        peval(f"location.href = '{sv.BASE}/panel'; 1")
        wait(lambda: panel()["content"]["line"].startswith("127.0.0.1"))
        w, h = window()
        f = st["frame"]
        t.ok("beside the page on the far side, as wide as a panel", f and f[2] == WIDTH and f[0] + f[2] == w - GAP, (f, w))

        # The cookie is the tabs' cookie.
        peval("document.cookie = 'fromPanel=yes; path=/'; 1")
        b = sv.page("b")
        cookie = sv.ev(b, "document.cookie")
        t.ok("a cookie set in the panel is the tabs' cookie", "fromPanel=yes" in (cookie or ""), cookie)

        # It keeps to the web.
        peval("location.href = 'file:///etc/hosts'; 1"); time.sleep(1.0)
        t.ok("a file on this Mac doesn't load in it", panel()["page"].startswith(sv.BASE), panel()["page"])

        # The same site again closes it; the tab's menu puts one there.
        panel("site", url=f"{sv.BASE}/panel")
        t.ok("the same site again closes it", not panel()["shown"], panel())
        panel("site", tab=b)
        st = panel()
        t.ok("Open in Side Panel from a tab's menu", st["shown"] and st["content"]["url"].endswith("/b"), st)

        # Never a private tab's page.
        panel("close")
        sv.sp("private"); time.sleep(0.6)
        shy = sv.sp("state")["activeID"]
        panel("site", tab=shy)
        t.ok("a private tab's page never goes there", not panel()["shown"], panel())

        # Into a tab of its own.
        panel("site", url=f"{sv.BASE}/kept")
        wait(lambda: panel()["page"].endswith("/kept"))
        before = len(urls())
        panel("totab"); time.sleep(0.8)
        t.ok("into a tab: the panel closes and the page is a tab", not panel()["shown"] and len(urls()) == before + 1
             and any(u.endswith("/kept") for u in urls()), (panel(), urls()))
        panel("site", url=f"{sv.BASE}/panel")
        wait(lambda: panel()["title"] == "panel")
        # A page that keeps crashing is made again twice, then left.
        for _ in range(3):
            r = panel("crash"); time.sleep(0.3)
        t.ok("a crashing page is made again at most twice a minute", r.get("reloads") == 2 and r.get("gaveUp") is True, r)
        sv.quit()

        # Another space, one that starts afresh: the site comes again,
        # signed in as that space is.
        sv.setup(sidebar=True, spaces=True, **{"panel.sites": True})
        sv.launch()
        sv.page("a")
        panel("site", url=f"{sv.BASE}/panel")
        wait(lambda: panel()["title"] == "panel")
        first = panel()["content"]
        peval("document.cookie = 'space=one; path=/'; 1")
        sv.cmd({"do": "space", "action": "new", "name": "Fresh", "fresh": True}); time.sleep(1.2)
        st = panel()
        t.ok("another space: still up, now in that space", st["shown"] and st["content"].get("space") != first["space"]
             and st["content"]["sameStore"] is True, (first, st["content"]))
        wait(lambda: panel()["title"] == "panel")
        t.ok("another space: signed in as it is (none of the first space's cookies)",
             "space=one" not in (peval("document.cookie") or ""), peval("document.cookie"))
        sv.quit()
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
