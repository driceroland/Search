#!/usr/bin/env python3
"""SharePoint's "Open in Desktop App" (idea 1215) and OneDrive's "Open in
desktop" (idea 1315), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/office_desktop_app.py`.

Excel and Word for the web run in a frame of another site inside the
SharePoint page (officeapps.live.com in tenant.sharepoint.com). Clicking
"Open in Desktop App" in that frame has the frame's script hand the
ms-excel:/ms-word: link over, by navigating itself or a hidden frame, a
moment after the click. Here the page is on 127.0.0.1 and its frame on
localhost: two sites, as there. OneDrive's pages (/od) pass the request
between the host page and Word's frame of another site, either way.

A test run opens no other app: it says what it would have done (the
probe's `handedOff`): "asked" (the Open "Excel"? question), "no app" (no
app for the link on this Mac), or "ignored" (dropped without a word).
Nothing is clicked on screen: `tap` sends the click to the hidden view.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("office-desktop-app")
t = sv.T()

LINK = "ms-excel:ofe|u|https://contoso.sharepoint.com/sites/x/Shared%20Documents/Book%201.xlsx"
WORD = "ms-word:ofe|u|https://d.docs.live.net/0123456789abcdef/Documents/Doc%201.docx"
_served = sv.H.do_GET

ACTIONS = {
    # The frame goes to the link itself.
    "self": f"location.href = {LINK!r};",
    # A hidden frame of its own goes there.
    "hidden": f"var f = document.createElement('iframe'); f.style.display = 'none'; f.src = {LINK!r}; document.body.appendChild(f);",
    # After an "Opening in the desktop app…" screen of a second.
    "later": f"document.body.textContent = 'Opening…'; setTimeout(function () {{ location.href = {LINK!r}; }}, 1000);",
}


def _get(self):
    port = self.server.server_port
    path, _, mode = self.path.partition("?")
    if path == "/sp":
        body = (f"<!doctype html><meta charset=utf-8><title>sp</title><style>body{{margin:0}}</style>"
                f"<iframe id=f src='http://localhost:{port}/xl?{mode}' style='width:400px;height:200px;border:0'></iframe>")
    elif path == "/xl":
        if mode == "unasked":
            # No click: the frame of another site goes there on its own.
            script = f"setTimeout(function () {{ location.href = {LINK!r}; }}, 600);"
            body = f"<!doctype html><meta charset=utf-8><body><script>{script}</script>"
        else:
            body = ("<!doctype html><meta charset=utf-8><style>body{margin:0}button{width:400px;height:200px}</style>"
                    f"<button id=go>Open in Desktop App</button><script>document.getElementById('go').onclick = function () {{ {ACTIONS[mode]} }};</script>")
    elif path == "/od":
        # OneDrive's shape: the host page (onedrive.live.com) with Word for
        # the web in a frame of another site (word.cloud.microsoft or
        # officeapps.live.com), the two passing the request between them.
        if mode == "down":
            # The host's own "Open in app" button asks the Word frame, which
            # hands the link over.
            body = (f"<!doctype html><meta charset=utf-8><style>body{{margin:0}}button{{width:400px;height:200px}}</style>"
                    f"<button id=go>Open in app</button><iframe id=f src='http://localhost:{port}/wd?down'></iframe>"
                    "<script>document.getElementById('go').onclick = function () { document.getElementById('f').contentWindow.postMessage('open', '*'); };</script>")
        else:
            # The Word frame's button asks the host page, which hands the link
            # over from a hidden frame of its own.
            body = (f"<!doctype html><meta charset=utf-8><title>od</title><style>body{{margin:0}}</style>"
                    f"<iframe id=f src='http://localhost:{port}/wd?up' style='width:400px;height:200px;border:0'></iframe>"
                    f"<script>addEventListener('message', function (e) {{ if (e.data !== 'open') return; {ACTIONS['hidden']} }});</script>")
    elif path == "/wd":
        if mode == "down":
            body = (f"<!doctype html><meta charset=utf-8><script>addEventListener('message', function (e) {{ if (e.data === 'open') location.href = {WORD!r}; }});</script>")
        else:
            body = ("<!doctype html><meta charset=utf-8><style>body{margin:0}button{width:400px;height:200px}</style>"
                    "<button id=go>Open in Desktop App</button><script>document.getElementById('go').onclick = function () { parent.postMessage('open', '*'); };</script>")
    elif path == "/own":
        # The page's own button, on its own site: the control.
        body = (f"<!doctype html><meta charset=utf-8><style>body{{margin:0}}button{{width:400px;height:200px}}</style>"
                f"<button id=go onclick=\"location.href = {LINK!r}\">Open</button>")
    else:
        return _served(self)
    data = body.encode()
    self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8")
    self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)


sv.H.do_GET = _get


def handed(): return sv.cmd({"do": "probe"})["handedOff"]


def run(path, selector, wait):
    before = len(handed())
    page = sv.cmd({"do": "open", "url": f"{sv.BASE}{path}"}); time.sleep(2)
    if selector:
        sv.cmd({"do": "tap", "id": page["id"], "selector": selector})
    time.sleep(wait)
    return handed()[before:]


HANDED = ("ms-excel: asked", "ms-excel: no app")

try:
    sv.setup(); sv.launch()
    got = run("/own", "#go", 1.5)
    t.ok("the page's own button: handed over", len(got) == 1 and got[0] in HANDED, got)
    for mode, wait in (("self", 1.5), ("hidden", 1.5), ("later", 2.5)):
        got = run(f"/sp?{mode}", "#f", wait)
        t.ok(f"a click in a frame of another site ({mode}): handed over, once", len(got) == 1 and got[0] in HANDED, got)
    # OneDrive (onedrive.live.com, Word for the web in a frame of another site).
    got = run("/od?up", "#f", 1.5)
    t.ok("OneDrive: a click in Word's frame, the host page hands over: once", len(got) == 1 and got[0] in HANDED, got)
    got = run("/od?down", "#go", 1.5)
    t.ok("OneDrive: a click on the host page, Word's frame hands over: once (idea 1315)", len(got) == 1 and got[0] in ("ms-word: asked", "ms-word: no app"), got)
    got = run("/sp?unasked", None, 2)
    t.ok("a frame of another site with no click: still ignored", got == ["ms-excel: ignored"], got)
finally:
    sv.finish()
t.done()
sys.exit(1 if t.failed else 0)
