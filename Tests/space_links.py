#!/usr/bin/env python3
"""Send links to a space (SpaceRoutes.swift), checked in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/space_links.py`. The app
starts hidden in a world of its own (see split_view.use) with spaces and
Send links to a space on, a second space "Two", and one rule: localhost to
Two. Pages are served from 127.0.0.1, which no rule names, and link to
localhost on the same port. Checked:

- a link from another app to localhost opens in Two, and Search switches to it;
- one to 127.0.0.1 opens where you are;
- a target=_blank click and a ⌘-click from a page in the first space open
  their localhost tab in Two, and not in the first space;
- a plain link followed in its own tab stays in its space;
- the same links from a private tab stay in the first space.

Nothing here makes, shows or brings forward a window.
"""
import json
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("space-links")

LINK = 'style="display:block;font-size:60px;line-height:120px;padding:0 20px"'
PORT = sv.srv.server_port
LOCAL = f"http://localhost:{PORT}"


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        page = urlparse(self.path).path
        if page == "/blank":
            body = f'<a id="go" target="_blank" href="{LOCAL}/opened-blank" {LINK}>link</a>'
        elif page == "/cmd":
            body = f'<a id="go" href="{LOCAL}/opened-cmd" {LINK}>link</a>'
        elif page == "/same":
            body = f'<a id="go" href="{LOCAL}/opened-same" {LINK}>link</a>'
        elif page == "/shy":
            body = f'<a id="go" target="_blank" href="{LOCAL}/opened-shy" {LINK}>link</a>'
        else:
            body = f"<title>{page}</title>opened {page}"
        data = ("<!doctype html><meta charset=utf-8>" + body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


sv.srv.RequestHandlerClass = H


def space(**f): return sv.cmd({"do": "space", **f})
def tabs(): return sv.cmd({"do": "tabs"})["tabs"]
def paths(): return [urlparse(t["url"]).path for t in tabs()]
def link(url): sv.cmd({"do": "windows", "action": "link", "url": url})
def current(): return space()["current"]


def home():
    """Back to the first space, and its tabs."""
    space(action="go", index=1); time.sleep(0.8)


def opened(url, wait=1.0):
    r = sv.sp("open", url=url)["resultID"]; time.sleep(wait); return r


def main():
    t = sv.T()
    try:
        sv.setup(**{"spaces": True, "spaces.links": True, "start.fresh": False})
        sv.launch()
        space(action="new", name="Two"); time.sleep(0.8)
        two = next(s["id"] for s in json.load(open(f"{sv.SUPPORT}/spaces.json")) if s["name"] == "Two")
        # The rule, written as Settings writes it, read at the next launch.
        sv.quit(); time.sleep(1)
        subprocess.run(["defaults", "write", sv.SUITE, "spaces.links.rules", "-array",
                        f'{{ site = localhost; space = "{two}"; }}'], check=True)
        sv.launch(); time.sleep(1)
        home()
        first = current()
        t.ok("in the first space to begin with", first != "Two", first)

        # From another app.
        link(f"{LOCAL}/ext"); time.sleep(1.5)
        t.ok("a link from another app to localhost switches to Two", current() == "Two", current())
        t.ok("and opens there", "/ext" in paths(), paths())
        home()
        t.ok("not in the first space", "/ext" not in paths(), paths())
        link(f"{sv.BASE}/elsewhere"); time.sleep(1.5)
        t.ok("a link no rule names stays where you are", current() == first and "/elsewhere" in paths(), (current(), paths()))

        # From a page in the first space.
        page = opened(f"{sv.BASE}/blank")
        sv.cmd({"do": "tap", "id": page, "selector": "#go"}); time.sleep(2)
        t.ok("a target=_blank click to localhost switches to Two", current() == "Two", current())
        t.ok("and opens there", "/opened-blank" in paths(), paths())
        home()
        t.ok("no tab for it in the first space", "/opened-blank" not in paths(), paths())

        page = opened(f"{sv.BASE}/cmd")
        sv.cmd({"do": "tap", "id": page, "selector": "#go", "mods": ["cmd"]}); time.sleep(2)
        t.ok("a ⌘-click to localhost opens in Two", current() == "Two" and "/opened-cmd" in paths(), (current(), paths()))
        home()

        page = opened(f"{sv.BASE}/same")
        sv.cmd({"do": "tap", "id": page, "selector": "#go"}); time.sleep(2)
        t.ok("a link followed in its own tab stays in its space",
             current() == first and "/opened-same" in paths(), (current(), paths()))

        # A private tab's links are never sent.
        before = sv.sp("state")
        sv.sp("private"); time.sleep(0.6)
        shy = sv.sp("state")["activeID"]
        sv.cmd({"do": "go", "id": shy, "url": f"{sv.BASE}/shy"}); time.sleep(1.2)
        sv.cmd({"do": "tap", "id": shy, "selector": "#go"}); time.sleep(2)
        t.ok("a private tab's target=_blank link stays in the first space",
             current() == first and "/opened-shy" in paths(), (current(), paths(), before.get("activeID")))
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
