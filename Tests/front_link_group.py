#!/usr/bin/env python3
"""A link that opens in front, out of a grouped tab, joins the group.

Build first (`./build.sh debug`), then `python3 Tests/front_link_group.py`.
The app starts hidden in a world of its own (see split_view.use), is driven
with trusted clicks (`tap`), and is quit; its world is removed afterwards.

A plain click on a target=_blank link, or a page's window.open on a click,
opens its page in front. From a grouped tab it went to the end of the row,
outside the group, though Settings › Tabs › New tab position says a link
from a group stays in it, and a ⌘-click's tab does join it.
"""
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("front-link-group")

STYLE = 'style="display:block;font-size:30px;line-height:60px;padding:0 20px"'


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        page = urlparse(self.path).path
        if page.startswith("/links"):
            body = (f'<title>links</title>'
                    f'<a id="b1" target="_blank" href="/front-1" {STYLE}>front 1</a>'
                    f'<a id="b2" target="_blank" href="/front-2" {STYLE}>front 2</a>'
                    f'<button id="w1" onclick="window.open(\'/script-1\')" {STYLE}>script 1</button>')
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


def paths(st):
    return [urlparse(x["url"]).path for x in st["tabs"]]


def members(st, of):
    group = next(gid for tab, gid in zip(st["tabs"], st["groupIDs"]) if tab["id"] == of)
    return group, [urlparse(tab["url"]).path for tab, gid in zip(st["tabs"], st["groupIDs"]) if group and gid == group]


def click(tab, anchor, wait=1.2):
    sv.cmd({"do": "tap", "id": tab, "selector": f"#{anchor}"})
    time.sleep(wait)


def run(t, place):
    sv.setup(sidebar=True, **{"tabs.groups": True})
    if place != "next":
        subprocess.run(["defaults", "write", sv.SUITE, "tabs.newPlace", place], check=True)
    sv.launch()
    try:
        g = sv.page("links")
        sv.page("other")
        sv.page("tail")
        sv.sp("group", id=g); time.sleep(0.4)
        sv.sp("select", id=g); time.sleep(0.4)

        click(g, "b1")
        st = state()
        group, inside = members(st, g)
        t.ok(f"{place}: a clicked target=_blank link joins its page's group", "/front-1" in inside, (inside, paths(st)))
        t.ok(f"{place}: the new page is in front", paths(st)[[x["id"] for x in st["tabs"]].index(st["activeID"])] == "/front-1")
        t.ok(f"{place}: tabs outside the group stay outside", "/other" not in inside and "/tail" not in inside, inside)

        sv.sp("select", id=g); time.sleep(0.4)
        click(g, "w1", wait=1.6)
        st = state()
        _, inside = members(st, g)
        t.ok(f"{place}: a page's window.open on a click joins the group too", "/script-1" in inside, (inside, paths(st)))
        if place == "next":
            t.ok("next: a page opened in front goes to the end of the group, as to the end of the row",
                 inside == ["/links", "/front-1", "/script-1"], inside)
    finally:
        sv.finish()


def run_loose(t):
    """Out of a tab in no group, nothing changes: the end of the row."""
    sv.setup(sidebar=True, **{"tabs.groups": True})
    sv.launch()
    try:
        s = sv.page("links")
        sv.page("tail")
        sv.sp("select", id=s); time.sleep(0.4)
        click(s, "b1")
        st = state()
        t.ok("loose: still the end of the row, in no group",
             paths(st)[-1] == "/front-1" and not st["groupIDs"][-1], paths(st))
    finally:
        sv.finish()


def main():
    t = sv.T()
    try:
        run(t, "next")
        run(t, "top")
        run_loose(t)
    finally:
        t.done()
    return 1 if t.failed else 0


if __name__ == "__main__":
    if sys.platform != "darwin":
        sys.exit("Tests/front_link_group.py requires macOS and a built Search.app")
    sys.exit(main())
