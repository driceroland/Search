#!/usr/bin/env python3
"""One click, at most one new tab, checked in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/one_click_one_tab.py`. The
app starts hidden in a world of its own (see split_view.use), is driven
through ./bench's socket with trusted clicks (`tap`), and is quit; its
world is removed afterwards. Local pages only: no accounts, no sites.

Gmail's links are <a target=_blank> whose own click handler also calls
window.open, for the same address or a redirect to it. A click there made
two tabs (17 Oct 2026). Every case below must make exactly one.
"""
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse, parse_qs

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("dbl-tests")

LINK = 'style="display:block;font-size:60px;line-height:120px;padding:0 20px"'


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)
        page = url.path
        if page == "/redir":
            # google.com/url's part: a page that sends you on.
            to = parse_qs(url.query).get("q", ["/"])[0]
            self.send_response(302)
            self.send_header("Location", to)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if page == "/anchor":
            body = f'<a id="go" target="_blank" href="/opened-anchor" {LINK}>link</a>'
        elif page == "/wopen":
            body = f'<button id="go" onclick="window.open(\'/opened-wopen\')" {LINK}>open</button>'
        elif page == "/gmail":
            # The anchor opens by itself, and the page's handler opens too.
            body = f'''<a id="go" target="_blank" href="/opened-gmail" {LINK}>link</a><script>
            document.querySelector('#go').addEventListener('click', e => window.open(e.currentTarget.href, '_blank'));
            </script>'''
        elif page == "/gmail-aux":
            # The middle button fires auxclick, not click: a page opening
            # from there too.
            body = f'''<a id="go" target="_blank" href="/opened-gmaila" {LINK}>link</a><script>
            document.querySelector('#go').addEventListener('auxclick', e => {{ if (e.button === 1) window.open(e.currentTarget.href); }});
            </script>'''
        elif page == "/gmail-redirect":
            # The same, the handler going through a redirect to the address.
            body = f'''<a id="go" target="_blank" href="/opened-gmailr" {LINK}>link</a><script>
            document.querySelector('#go').addEventListener('click', () => window.open('/redir?q=/opened-gmailr'));
            </script>'''
        elif page == "/gmail-rewrite":
            # Gmail's safe-redirect swap on mousedown, then the anchor itself.
            body = f'''<a id="go" target="_blank" href="/opened-gmailw" data-saferedirecturl="/redir?q=/opened-gmailw" {LINK}>link</a><script>
            const a = document.querySelector('#go');
            a.addEventListener('mousedown', () => {{ a.href = a.dataset.saferedirecturl; }});
            </script>'''
        elif page == "/post":
            body = f'''<button id="go" onclick="run()" {LINK}>POST sign-in</button>
            <form id="signin" method="post" target="_blank" action="/opened-post">
            <input name="assertion" value="fake-test-only"></form><script>
            async function run() {{ await fetch('/delay'); document.querySelector('#signin').submit(); }}
            </script>'''
        elif page == "/delay":
            time.sleep(2)
            body = "ready"
        elif page == "/plain":
            body = f'<a id="go" href="/opened-plain" {LINK}>link</a>'
        else:
            body = f"<title>{page}</title>opened {page}"
        self.respond(body)

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.respond("POST received")

    def respond(self, body):
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


def tabs():
    return sv.cmd({"do": "tabs"})["tabs"]


def tap(tab, **extra):
    sv.cmd({"do": "tap", "id": tab, "selector": "#go", **extra})


def count_new(before, wait):
    """Tabs added since `before`, once `wait` seconds have passed."""
    time.sleep(wait)
    ids = {t["id"] for t in before}
    return [t for t in tabs() if t["id"] not in ids]


def case(t, name, path, expect, wait=2.5, behind=False, **extra):
    page = sv.page(path)
    before = tabs()
    tap(page, **extra)
    note = sv.cmd({"do": "probe"})["announcement"]
    until = time.monotonic() + 1
    while behind and not note and time.monotonic() < until:
        time.sleep(0.05)
        note = sv.cmd({"do": "probe"})["announcement"]
    t.ok(f"{name}: toast only for a background tab", note == ("Opened in a new tab" if behind else ""), note)
    new = count_new(before, wait)
    t.ok(f"{name}: one new tab", [urlparse(x["url"]).path for x in new] == [f"/opened-{expect}"],
         [urlparse(x["url"]).path for x in new])
    if behind:
        t.ok(f"{name}: it stays behind", new and not any(x["active"] for x in new),
             [(urlparse(x["url"]).path, x["active"]) for x in new])
        t.ok(f"{name}: toast goes away", not sv.cmd({"do": "probe"})["announcement"])
    return page


def main():
    t = sv.T()
    try:
        sv.setup(sidebar=True, **{"sidebar.hides": True}); sv.launch()
        case(t, "anchor target=_blank", "anchor", "anchor")
        case(t, "window.open only", "wopen", "wopen")
        case(t, "anchor + window.open, same address (Gmail)", "gmail", "gmail")
        case(t, "anchor + window.open through a redirect", "gmail-redirect", "gmailr")
        case(t, "href swapped to a redirect on mousedown", "gmail-rewrite", "gmailw")
        case(t, "async POST to _blank after a click (#509)", "post", "post", wait=4)
        case(t, "⌘-click a plain link", "plain", "plain", behind=True, mods=["cmd"])
        case(t, "⌘⇧-click a plain link", "plain", "plain", mods=["cmd", "shift"])
        case(t, "⌘-click on the Gmail pattern", "gmail", "gmail", behind=True, mods=["cmd"])
        case(t, "⌘-click, the page opening through a redirect", "gmail-redirect", "gmailr", behind=True, mods=["cmd"])
        case(t, "middle-click a plain link", "plain", "plain", behind=True, button="middle")
        case(t, "middle-click, the page opening on auxclick", "gmail-aux", "gmaila", behind=True, button="middle")
        # And the next click still opens its one tab.
        case(t, "a click after all that", "anchor", "anchor")
        page = sv.page("plain")
        sv.cmd({"do": "linkmenu", "id": page, "x": 80, "y": 60, "pick": "Open Link in New Tab"})
        t.ok("Open Link in New Tab: shows a toast", sv.cmd({"do": "probe"})["announcement"] == "Opened in a new tab")
    finally:
        t.done(); sv.finish()
    return 1 if t.failed else 0


if __name__ == "__main__":
    if sys.platform != "darwin":
        sys.exit("Tests/one_click_one_tab.py requires macOS and a built Search.app")
    sys.exit(main())
