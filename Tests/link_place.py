#!/usr/bin/env python3
"""Where a link opened out of a page goes, checked in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/link_place.py`. The app
starts hidden in a world of its own (see split_view.use), is driven through
./bench's socket with trusted clicks (`tap`), and is quit; its world is
removed afterwards. Local pages only.

With New tab position on After current (the default), links opened behind a
page — ⌘-click, the middle button, Open Link in New Tab, a page's own
window.open on a ⌘-click — go right after it, in the order they were clicked,
as in Safari, Chrome and Arc; they went in reverse, each straight after the
page (X, 26 Oct 2026). The run starts again after going to another tab or
the page going somewhere else. In a group the run stays in it; a pair in
Split View is one place.
"""
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("link-place")

STYLE = 'style="display:block;font-size:30px;line-height:60px;padding:0 20px"'


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        page = urlparse(self.path).path
        if page.startswith("/links"):
            links = "".join(f'<a id="l{n}" href="/opened-{n}" {STYLE}>link {n}</a>' for n in range(1, 7))
            # Gmail's: the anchor's own window.open in its click handler.
            gmail = "".join(f'<a id="g{n}" target="_blank" href="/gmail-{n}" {STYLE}>mail {n}</a>' for n in range(1, 3))
            body = f'''<title>links</title>{links}{gmail}<script>
            document.querySelectorAll('[id^=g]').forEach(a => a.addEventListener('click', e => window.open(e.currentTarget.href, '_blank')));
            </script>'''
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


def state():
    return sv.sp("state")


def paths(st=None):
    st = st or state()
    return [urlparse(x["url"]).path for x in st["tabs"]]


def click(tab, anchor, wait=1.2, **extra):
    sv.cmd({"do": "tap", "id": tab, "selector": f"#{anchor}", **({"mods": ["cmd"]} | extra)})
    time.sleep(wait)


def after(st, opener):
    """The paths of the tabs right after `opener`, up to the next one not opened from a link here."""
    p = paths(st)
    i = [x["id"] for x in st["tabs"]].index(opener)
    out = []
    for one in p[i + 1:]:
        if not (one.startswith("/opened-") or one.startswith("/gmail-")):
            break
        out.append(one)
    return out


def run(t, sidebar):
    where = "column" if sidebar else "across the top"
    sv.setup(sidebar=sidebar, **{"tabs.groups": True, "splitView": True})
    sv.launch()
    try:
        x = sv.page("x")
        s = sv.page("links")
        y = sv.page("y")
        sv.sp("select", id=s); time.sleep(0.4)

        click(s, "l1"); click(s, "l2"); click(s, "l3")
        st = state()
        t.ok(f"{where}: three ⌘-clicks go after their page, in click order",
             after(st, s) == ["/opened-1", "/opened-2", "/opened-3"], paths(st))
        t.ok(f"{where}: the page stays in front, the tabs either side untouched",
             st["activeID"] == s and paths(st)[paths(st).index("/links") - 1] == "/x" and paths(st)[-1] == "/y",
             (st["activeID"], paths(st)))
        if not sidebar:
            return

        click(s, "l4", button="middle")
        t.ok("a middle-click carries on the run", after(state(), s)[-1] == "/opened-4", paths())
        r = sv.cmd({"do": "linkmenu", "id": s, "x": 60, "y": 270, "pick": "Open Link in New Tab"})
        time.sleep(0.8)
        t.ok("Open Link in New Tab carries on the run", after(state(), s)[-1] == "/opened-5", (r.get("urls"), paths()))

        # Going to another tab and back starts again, straight after the page.
        sv.sp("select", id=y); time.sleep(0.3); sv.sp("select", id=s); time.sleep(0.3)
        click(s, "l6")
        t.ok("after going to another tab, the next link is straight after the page",
             after(state(), s)[0] == "/opened-6", paths())

        # The Gmail pattern: the page's window.open is the ⌘-click's tab,
        # and it carries on the run too.
        click(s, "g1", wait=1.8); click(s, "g2", wait=1.8)
        st = state()
        got = after(st, s)
        t.ok("a page's own window.open on ⌘-click goes after the page too, in click order",
             got[:3] == ["/opened-6", "/gmail-1", "/gmail-2"] and st["activeID"] == s, (st["activeID"], paths(st)))

        # The page going somewhere else starts again too.
        sv.cmd({"do": "go", "id": s, "url": f"{sv.BASE}/links-again"}); time.sleep(1)
        click(s, "l1")
        t.ok("after the page goes elsewhere, the next link is straight after it",
             after(state(), s)[0] == "/opened-1", paths())

        # In a group: the run stays in the group, right after the page.
        g = sv.page("links-grouped")
        sv.page("tail")
        sv.sp("group", id=g)
        sv.sp("select", id=g); time.sleep(0.3)
        click(g, "l1"); click(g, "l2")
        st = state()
        group = next(gid for tab, gid in zip(st["tabs"], st["groupIDs"]) if tab["id"] == g)
        members = [urlparse(tab["url"]).path for tab, gid in zip(st["tabs"], st["groupIDs"]) if gid == group]
        t.ok("in a group: the links join it, after the page, in click order",
             members == ["/links-grouped", "/opened-1", "/opened-2"], members)
        t.ok("in a group: the tab after the group stays out of it",
             paths(st).index("/tail") > paths(st).index("/opened-2") and "/tail" not in members, paths(st))

        # In Split View: a pair is one place, the links go after it.
        p = sv.page("links-left")
        q = sv.page("partner")
        sv.sp("pair", id=q, **{"with": p, "side": "right"})
        sv.sp("select", id=p); time.sleep(0.4)
        click(p, "l1"); click(p, "l2")
        st = state()
        i = [x["id"] for x in st["tabs"]].index(q)
        t.ok("in Split View: after the pair, in click order",
             paths(st)[i + 1:i + 3] == ["/opened-1", "/opened-2"], paths(st))
        t.ok("in Split View: the pair is still a pair", any(set(pair["tabs"]) == {p, q} for pair in st["splits"]), st["splits"])
    finally:
        sv.finish()


def run_top(t):
    """With new tabs at the top, a ⌘-click still goes under its page, as in Arc."""
    sv.setup(sidebar=True)
    subprocess.run(["defaults", "write", sv.SUITE, "tabs.newPlace", "top"], check=True)
    sv.launch()
    try:
        sv.page("x")
        s = sv.page("links")
        sv.sp("select", id=s); time.sleep(0.4)
        click(s, "l1"); click(s, "l2")
        st = state()
        t.ok("Top: ⌘-clicks go under their page, in click order, not to the top",
             after(st, s) == ["/opened-1", "/opened-2"], paths(st))
        blank = sv.sp("newTab")["activeID"]
        t.ok("Top: ⌘T's tab still goes to the top", [x["id"] for x in state()["tabs"]][0] == blank, paths())
    finally:
        sv.finish()


def main():
    t = sv.T()
    try:
        run(t, sidebar=True)
        run(t, sidebar=False)
        run_top(t)
    finally:
        t.done()
    return 1 if t.failed else 0


if __name__ == "__main__":
    if sys.platform != "darwin":
        sys.exit("Tests/link_place.py requires macOS and a built Search.app")
    sys.exit(main())
