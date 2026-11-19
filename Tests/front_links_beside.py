#!/usr/bin/env python3
"""Settings › Tabs › Links opened in front go beside their page.

Build first (`./build.sh debug`), then `python3 Tests/front_links_beside.py`.
The app starts hidden in a world of its own (see split_view.use), is driven
with trusted clicks (`tap`) and ⌘W (`press`), and is quit; its world is
removed afterwards. Local pages only.

With New tab position on After current, a plain click on a target=_blank
link, a page's window.open on a click, or a ⇧⌘-click put its page at the end
of the row (⇧⌘-click: straight after the page, the last clicked first). With
the switch on they go where a ⌘-click's goes: after the page and the ones it
already opened, in click order, while you go back and forth between the page
and those tabs. Off, nothing changes.
"""
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("front-links-beside")

STYLE = 'style="display:block;font-size:22px;line-height:40px;padding:0 20px"'


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        page = urlparse(self.path).path
        if page.startswith("/links"):
            body = "<title>links</title>" + "".join(
                f'<a id="b{n}" target="_blank" href="/front-{n}" {STYLE}>front {n}</a>'
                f'<a id="p{n}" href="/plain-{n}" {STYLE}>plain {n}</a>'
                f'<button id="w{n}" onclick="window.open(\'/script-{n}\')" {STYLE}>script {n}</button>'
                for n in range(1, 5))
        else:
            body = f"<title>{page}</title>{page}"
        data = ("<!doctype html><meta charset=utf-8>" + body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


sv.srv.RequestHandlerClass = H


def state():
    return sv.sp("state")


def paths(st=None):
    return [urlparse(x["url"]).path for x in (st or state())["tabs"]]


def active_path(st=None):
    st = st or state()
    return next(urlparse(x["url"]).path for x in st["tabs"] if x["id"] == st["activeID"])


def by_path(path):
    return next(x["id"] for x in state()["tabs"] if urlparse(x["url"]).path == path)


def click(tab, anchor, wait=1.2, mods=None):
    if state()["activeID"] != tab:
        sv.sp("select", id=tab); time.sleep(0.4)
    req = {"do": "tap", "id": tab, "selector": f"#{anchor}"}
    if mods:
        req["mods"] = mods
    sv.cmd(req)
    time.sleep(wait)


def after(page, n):
    p = paths()
    i = p.index(page)
    return p[i + 1:i + 1 + n]


def world(on=True, place="next", **prefs):
    sv.setup(sidebar=True, **{"tabs.groups": True, "splitView": True, "tabs.frontBeside": on, "pins.peek": False, **prefs})
    if place != "next":
        subprocess.run(["defaults", "write", sv.SUITE, "tabs.newPlace", place], check=True)
    sv.launch()
    sv.page("left")
    s = sv.page("links")
    sv.page("right")
    sv.sp("select", id=s); time.sleep(0.4)
    return s


def run_on(t):
    s = world()
    try:
        for n in (1, 2, 3):
            click(s, f"b{n}")
            if n == 1:
                t.ok("on: the clicked link's page is in front", active_path() == "/front-1", active_path())
        t.ok("on: three clicked target=_blank links go after their page, in click order, going back between",
             after("/links", 4) == ["/front-1", "/front-2", "/front-3", "/right"], paths())

        # Going to another tab starts again, straight after the page.
        sv.sp("select", id=by_path("/right")); time.sleep(0.4)
        click(s, "b4")
        t.ok("on: after going to another tab, the next one is straight after the page",
             after("/links", 1) == ["/front-4"], paths())
    finally:
        sv.finish()

    s = world()
    try:
        for n in (1, 2, 3):
            click(s, f"w{n}", wait=1.6)
        t.ok("on: a page's window.open on a click goes the same way",
             after("/links", 3) == ["/script-1", "/script-2", "/script-3"], paths())
    finally:
        sv.finish()

    s = world()
    try:
        for n in (1, 2, 3):
            click(s, f"p{n}", mods=["cmd", "shift"])
        t.ok("on: ⇧⌘-clicks, in front, go in click order too",
             after("/links", 3) == ["/plain-1", "/plain-2", "/plain-3"], paths())
    finally:
        sv.finish()

    # Closing goes back to the page, so the run is still on when it gets there.
    s = world(**{"tabs.closeGoesBack": True})
    try:
        # ⌘-clicks, then a look at one of them and back: the run goes on.
        click(s, "p1", mods=["cmd"]); click(s, "p2", mods=["cmd"])
        sv.sp("select", id=by_path("/plain-1")); time.sleep(0.4)
        click(s, "b1")
        t.ok("on: a click after a look at a ⌘-clicked tab goes after the run",
             after("/links", 3) == ["/plain-1", "/plain-2", "/front-1"], paths())
        # One of the run closed on the way back: after the ones still there.
        sv.sp("select", id=by_path("/front-1")); time.sleep(0.4)
        sv.cmd({"do": "press", "code": 13, "chars": "w", "mods": ["cmd"]}); time.sleep(0.8)
        click(s, "b2")
        t.ok("on: with the last of the run closed, the next goes after the ones left",
             after("/links", 3) == ["/plain-1", "/plain-2", "/front-2"], paths())
    finally:
        sv.finish()

    s = world()
    try:
        sv.sp("group", id=s); time.sleep(0.4)
        click(s, "b1"); click(s, "b2")
        st = state()
        group = next(gid for tab, gid in zip(st["tabs"], st["groupIDs"]) if tab["id"] == s)
        inside = [urlparse(tab["url"]).path for tab, gid in zip(st["tabs"], st["groupIDs"]) if group and gid == group]
        t.ok("on: from a grouped page, into the group after it, in click order",
             inside == ["/links", "/front-1", "/front-2"], (inside, paths(st)))
    finally:
        sv.finish()

    s = world()
    try:
        q = sv.page("partner")
        sv.sp("pair", id=q, **{"with": s, "side": "right"}); time.sleep(0.6)
        click(s, "b1")
        t.ok("on: a pair is one place: after the pair", after("/partner", 1) == ["/front-1"], paths())
    finally:
        sv.finish()

    s = world()
    try:
        sv.cmd({"do": "pin", "id": s}); time.sleep(0.6)
        click(s, "b1")
        st = state()
        pins = st.get("pinnedCount")
        p = paths(st)
        t.ok("on: from a pin (peek off), first after the pins", p.index("/front-1") == p.index("/links") + 1, p)
    finally:
        sv.finish()


def run_off_and_top(t):
    s = world(on=False)
    try:
        click(s, "b1"); click(s, "b2")
        t.ok("off: still the end of the row, as before", paths()[-2:] == ["/front-1", "/front-2"], paths())
    finally:
        sv.finish()

    s = world(on=True, place="top")
    try:
        click(s, "b1")
        t.ok("on, with Top: Top still decides for a page opened in front",
             paths().index("/front-1") < paths().index("/left"), paths())
    finally:
        sv.finish()


def main():
    t = sv.T()
    try:
        run_on(t)
        run_off_and_top(t)
    finally:
        t.done()
    return 1 if t.failed else 0


if __name__ == "__main__":
    if sys.platform != "darwin":
        sys.exit("Tests/front_links_beside.py requires macOS and a built Search.app")
    sys.exit(main())
