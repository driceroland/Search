#!/usr/bin/env python3
"""Sized website pop-ups (#552), through trusted clicks in an isolated hidden world.

Build with ./build.sh debug, then python3 Tests/website_popups.py [PICTURES].
Only local fixtures and fake cookies are used. Optional native window pictures
(light/dark, before/after) are saved outside the repository. No window is shown.
"""
import json
import re
import sys
import subprocess
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv

sv.use("website-popups")
PICTURES = Path(sys.argv[1]) if len(sys.argv) > 1 else None
posts = []


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/opener":
            body = """<h1>Website pop-up fixture</h1><p>Open a sized window for this site's call or sign-in.</p>
            <button id="sized" onclick="popup=window.open('/child', '_blank', 'width=420,height=360')">Open small window</button>
            <button id="plain" onclick="window.open('/plain')">Open ordinary tab</button>
            <button id="large" onclick="popup=window.open('/child', '_blank', 'width=100000,height=100000')">Oversized</button>
            <button id="twice" onclick="popup=window.open('/child', '_blank', 'width=420,height=360'); window.open('/duplicate', '_blank', 'width=420,height=360')">Two for one click</button>
            <button id="post" onclick="popup=window.open('', 'signin', 'width=420,height=360'); document.querySelector('form').submit()">POST sign-in</button>
            <form method="post" target="signin" action="/posted"><input name="assertion" value="fake-test-only"></form>
            <script>window.messages=[]; addEventListener('message', e => messages.push(e.data));</script>"""
        elif path == "/auto":
            body = "<script>setTimeout(() => window.open('/child','_blank','width=420,height=360'),300)</script>blocked pop-up"
        elif path == "/child":
            body = """<h1>Site window</h1><p>This small window keeps its opener and sign-ins.</p>
            <button id="close" onclick="window.close()">Close window</button>
            <button id="plain" onclick="window.open('/plain-from-popup')">Open ordinary tab</button>
            <a id="link" href="/modified-from-popup">Open link</a>
            <button id="capture" onclick="capture()">Use microphone</button>
            <button id="camera" onclick="capture(true)">Use camera</button>
            <button id="notify" onclick="notificationResult='pending';Notification.requestPermission().then(r=>notificationResult=r)">Send notifications</button>
            <script>async function capture(camera=false) {
              window.permissionResult='pending';
              try { const stream=await navigator.mediaDevices.getUserMedia(camera?{video:true}:{audio:true});
                    stream.getTracks().forEach(t=>t.stop()); window.permissionResult='granted'; }
              catch(e) { window.permissionResult=e.name; }
            }</script>
            <script>if(opener) opener.postMessage({cookie:document.cookie, opener:true},location.origin)</script>"""
        else:
            body = "Ordinary linked page"
        self.respond(body)

    def do_POST(self):
        posts.append(self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode())
        self.respond("POST sign-in received")

    def respond(self, body):
        data = ("<!doctype html><meta charset=utf-8><title>Untrusted page title</title>"
                "<style>:root{color-scheme:light dark}body{font:16px system-ui;padding:24px}button{padding:10px;margin:6px}</style>" + body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


sv.srv.RequestHandlerClass = H


def windows():
    return sv.cmd({"do": "windows"})["windows"]


def tabs(window=1):
    return sv.cmd({"do": "tabs", "window": window})["tabs"]


def tap(tab, selector, window=1, **options):
    sv.cmd({"do": "select", "id": tab, "window": window})
    time.sleep(0.2)
    sv.cmd({"do": "tap", "id": tab, "selector": selector, "window": window, **options})
    time.sleep(1)


def evaluate(tab, js, window=1):
    return sv.cmd({"do": "eval", "id": tab, "js": js, "window": window}).get("value")


def child(window):
    return next(t for t in tabs(window) if urlparse(t["url"]).path == "/child")["id"]


def picture(name, window):
    if PICTURES is None:
        return
    PICTURES.mkdir(parents=True, exist_ok=True)
    for look in ("light", "dark"):
        sv.cmd({"do": "ui", "look": look})
        time.sleep(0.7)
        sv.cmd({"do": "pages", "on": True})
        try:
            sv.cmd({"do": "picture", "window": window, "path": str(PICTURES / f"{name}-{look}.png")})
        finally:
            sv.cmd({"do": "pages", "on": False})


def main():
    t = sv.T()
    try:
        sv.setup(); sv.launch()
        page = sv.page("opener")
        tap(page, "#sized")
        t.ok("off by default: a sized pop-up is still a tab", len(windows()) == 1 and len(tabs()) == 3, windows())
        picture("before-sized-popup", 1)
        sv.quit()

        sv.setup(**{"tabs.popupWindows": True})
        subprocess.run(["defaults", "write", sv.SUITE, "settings.page", "-string", "tabs"], check=True)
        sv.launch()
        if PICTURES:
            sv.cmd({"do":"ui", "settings":True})
            for look in ("light", "dark"):
                sv.cmd({"do":"ui", "look":look}); time.sleep(0.5)
                sv.cmd({"do":"picture", "path":str(PICTURES / f"settings-popup-windows-{look}.png"), "page":False})
            sv.cmd({"do":"ui", "settings":False})
        page = sv.page("opener")
        evaluate(page, "document.cookie='fixture=ordinary;path=/';true")
        tap(page, "#sized")
        ws = windows()
        t.ok("enabled: a sized pop-up has its own native window", len(ws) == 2, ws)
        if len(ws) != 2:
            return 1
        small = child(2)
        t.ok("popup contains exactly its requested page", len(tabs(2)) == 1)
        t.ok("requested window size is used", [float(n) for n in re.findall(r"-?\d+(?:\.\d+)?", ws[1]["frame"])][-2:] == [420, 360], ws[1])
        t.ok("opener can reach the returned window", evaluate(page, "popup.opener === window && popup.location.pathname === '/child'") is True)
        t.ok("child keeps sign-ins and messages its opener", evaluate(page, "messages.some(m => m.opener && m.cookie.includes('fixture=ordinary'))") is True)
        picture("after-sized-popup", 2)
        tap(small, "#capture", 2)
        t.ok("first-use microphone question belongs to the popup", "microphone" in sv.cmd({"do":"probe", "window":2})["asking"])
        if PICTURES:
            for look in ("light", "dark"):
                sv.cmd({"do":"ui", "look":look}); time.sleep(0.5)
                sv.cmd({"do":"picture", "window":2, "path":str(PICTURES / f"microphone-question-{look}.png"), "page":False})
        sv.cmd({"do":"press", "window":2, "code":36, "chars":"\r"})
        t.ok("Return does not grant the microphone", evaluate(small, "permissionResult", 2) == "pending")
        sv.cmd({"do":"press", "window":2, "code":53, "chars":"\u001b"})
        time.sleep(0.5)
        t.ok("Escape denies and settles the microphone request", evaluate(small, "permissionResult", 2) == "NotAllowedError" and not sv.cmd({"do":"probe", "window":2})["asking"], [evaluate(small,"permissionResult",2),sv.cmd({"do":"probe", "window":2})["asking"]])
        tap(small, "#capture", 2)
        sv.cmd({"do":"answer", "window":2, "with":"once"}); time.sleep(1)
        t.ok("allowing first-use microphone resolves a synthetic capture", evaluate(small, "permissionResult", 2) == "granted")
        tap(small, "#camera", 2)
        sv.cmd({"do":"answer", "window":2, "with":"no"}); time.sleep(0.3)
        t.ok("camera refusal settles its request", evaluate(small, "permissionResult", 2) == "NotAllowedError", [evaluate(small,"permissionResult",2), sv.cmd({"do":"probe", "window":2})["asking"]])
        tap(small, "#notify", 2)
        if "notifications" in sv.cmd({"do":"probe", "window":2})["asking"]:
            sv.cmd({"do":"answer", "window":2, "with":"no"})
        t.ok("notification permission settles after refusal", evaluate(small, "window.notificationResult", 2) == "denied")
        for description, options in (("Command-click", {"mods":["cmd"]}), ("Command-Shift-click", {"mods":["cmd","shift"]}), ("middle-click", {"button":"middle"})):
            before = len(tabs())
            tap(small, "#link", 2, **options)
            t.ok(description + " opens in the normal browser and keeps the popup single-page", len(tabs()) == before + 1 and len(tabs(2)) == 1)
        for pick, foreground in (("Open Link in New Tab", False), ("Open Link in New Tab and Go to It", True)):
            active = next(tab["id"] for tab in tabs() if tab["active"])
            path = "/menu-front" if foreground else "/menu-behind"
            point = evaluate(small, """(() => { const link = document.querySelector('#link');
                link.href = %s; link.scrollIntoView();
                const r = link.getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; })();
                """ % json.dumps(sv.BASE + path), 2)
            sv.cmd({"do": "linkmenu", "id": small, "window": 2, "x": point[0], "y": point[1], "pick": pick})
            made = [tab for tab in tabs() if urlparse(tab["url"]).path == path]
            t.ok(pick + " from a popup preserves foreground/background selection",
                 len(made) == 1 and next(tab["id"] for tab in tabs() if tab["active"]) == (made[0]["id"] if foreground else active)
                 and len(tabs(2)) == 1)
        tap(small, "#plain", 2)
        t.ok("ordinary links in the popup open a normal browser tab", any(urlparse(tab["url"]).path == "/plain-from-popup" for tab in tabs()) and len(tabs(2)) == 1)
        tap(small, "#close", 2)
        t.ok("window.close removes its window", len(windows()) == 1 and evaluate(page, "popup.closed") is True)
        t.ok("closed popup is not a reopenable window", sv.cmd({"do": "windows"})["closedWindows"] is False)

        tap(page, "#plain")
        t.ok("ordinary unsized window.open stays a tab", len(windows()) == 1 and any(urlparse(tab["url"]).path == "/plain" for tab in tabs()))
        before = len(tabs())
        sv.page("auto"); time.sleep(1)
        t.ok("setting does not bypass popup blocking", len(windows()) == 1 and len(tabs()) == before + 1)
        tap(page, "#twice")
        t.ok("one click cannot open duplicate windows", len(windows()) == 2 and not any("duplicate" in url for w in windows() for url in w["tabs"]))
        sv.cmd({"do": "windows", "action": "close", "n": 2})
        t.ok("native close updates the returned window", evaluate(page, "popup.closed") is True)

        tap(page, "#post")
        t.ok("blank popup accepts its named POST target and body", len(windows()) == 2 and any("/posted" in url for url in windows()[1]["tabs"]) and posts == ["assertion=fake-test-only"], posts)
        sv.cmd({"do": "windows", "action": "close", "n": 2})

        sv.sp("private")
        private = next(tab["id"] for tab in tabs() if tab["active"])
        sv.cmd({"do": "go", "id": private, "url": sv.BASE + "/opener"}); time.sleep(1)
        evaluate(private, "document.cookie='fixture=private;path=/';true")
        tap(private, "#sized")
        t.ok("private popup shares only its private opener's sign-ins", evaluate(private, "messages.some(m => m.cookie.includes('fixture=private'))") is True and "fixture=ordinary" in evaluate(page, "document.cookie"))
        private_child = child(2)
        tap(private_child, "#link", 2, mods=["cmd"])
        linked = next(tab for tab in tabs() if urlparse(tab["url"]).path == "/modified-from-popup" and tab["shy"])
        t.ok("modified private popup link keeps its private store", "fixture=private" in evaluate(linked["id"], "document.cookie"))
        sv.cmd({"do":"press", "window":2, "code":17, "chars":"t", "mods":["cmd"]})
        t.ok("new tab from a private popup goes to the browser privately", len(tabs(2)) == 1 and any(tab["shy"] and tab["active"] and not tab["url"] for tab in tabs()))
        sv.cmd({"do": "windows", "action": "close", "n": 2})

        sv.cmd({"do": "ui", "spaces": True})
        sv.cmd({"do": "space", "action": "new", "name": "Separate", "fresh": True})
        isolated = sv.page("opener")
        evaluate(isolated, "document.cookie='fixture=space;path=/';true")
        tap(isolated, "#sized")
        t.ok("popup keeps its originating Space", windows()[1]["space"] == "Separate", windows()[1])
        t.ok("isolated Space's cookies reach its popup", evaluate(isolated, "messages.some(m => m.cookie.includes('fixture=space'))") is True)
        isolated_child = child(2)
        sv.cmd({"do":"space", "action":"go", "index":1})
        tap(isolated_child, "#plain", 2)
        t.ok("an ordinary popup link returns to its source Space after switching", windows()[0]["space"] == "Separate")
        plain = next(tab["id"] for tab in tabs() if urlparse(tab["url"]).path == "/plain-from-popup")
        t.ok("returned tab keeps the source Space's sign-ins", "fixture=space" in evaluate(plain, "document.cookie"))
        sv.cmd({"do": "windows", "action": "close", "n": 2})
        tap(isolated, "#large")
        frame = [float(n) for n in re.findall(r"-?\d+(?:\.\d+)?", windows()[1]["frame"])]
        t.ok("oversized requests are bounded by a display", 200 <= frame[-2] < 100000 and 150 <= frame[-1] < 100000, frame)
        sv.quit()
        saved = json.loads(Path(sv.SUPPORT, "windows.json").read_text())
        t.ok("open popup is excluded from saved windows", len(saved) == 1, saved)
        sv.launch()
        t.ok("restart restores the browser without the popup", len(windows()) == 1, windows())
        restored = sv.page("opener")
        tap(restored, "#sized")
        t.ok("popup setting persists after restart", len(windows()) == 2)
        sv.cmd({"do":"ui", "spaces":False}); time.sleep(0.5)
        t.ok("disabling Spaces closes their transient popup", len(windows()) == 1)
        sv.cmd({"do":"ui", "spaces":True})
        sv.cmd({"do":"space", "action":"go", "index":2})
        restored = sv.page("opener")
        tap(restored, "#sized")
        sv.cmd({"do":"space", "action":"delete"}); time.sleep(0.5)
        t.ok("deleting the popup's originating Space closes it", len(windows()) == 1)
    finally:
        t.done(); sv.finish()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
