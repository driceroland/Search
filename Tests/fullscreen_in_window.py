#!/usr/bin/env python3
"""Settings › Video › Full screen in the window, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/fullscreen_in_window.py`.
With the switch on, a page's Fullscreen API is answered by Search rather
than by WebKit's own window and Space (WindowFullScreen.swift): the element
is laid over the page, the window's chrome steps aside, and the window goes
into macOS full screen unless it is there already. Nothing goes full screen
here: the bench pretends the window's own full screen, and counts how often
the window was asked into it or out (WindowFullScreen.pretend).

Checked: a request made from a key press fills the page, the chrome steps
aside, the window is asked into full screen once, and Escape, which the page
never sees, puts all three back; in a window already in full screen nothing
is asked of it either way; the page hears fullscreenchange before its
viewport grows, as in a real full screen, which YouTube's player lays its
controls out on (a window already in full screen kept them at 100px, 22 Nov
2026); a player in a frame of another site fills the window through its
frame, and leaves with it; another tab shown ends it; and the switch turned
off gives a page that is already up WebKit's own API back, and on again
Search's, without a reload. The window really going into its own Space, and
the video landing there, are checked by hand on a release candidate.
"""
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("fullscreen-in-window")
ESC = "\u001b"

# What the page saw, in order: its fullscreenchange events with the viewport
# at that moment, the resizes after them (only the browser's own), and any
# Escape that reached it. "f" asks for full screen, as a player's key does.
WATCH = """
<script>
window.__log = [];
document.addEventListener('fullscreenchange', function () {
  __log.push(['change', !!document.fullscreenElement, innerWidth, innerHeight]);
});
addEventListener('resize', function (e) {
  if (e.isTrusted) __log.push(['resize', innerWidth, innerHeight]);
});
addEventListener('keydown', function (e) {
  if (e.key === 'Escape') __log.push(['escape']);
  if (e.key === 'f') document.getElementById(TARGET).requestFullscreen();
});
</script>
"""


class Pages(BaseHTTPRequestHandler):
    def do_GET(self):
        port = self.server.server_port
        if self.path == "/player":
            body = ("<!doctype html><title>player</title><body style='margin:0'>"
                    "<div style='transform:translateX(10px);position:relative;z-index:1'>"
                    "<div id=player style='width:320px;height:180px;background:#08f'></div></div>"
                    "<p id=after>after</p>" + WATCH.replace("TARGET", "'player'"))
        elif self.path == "/embed":
            # The frame from another origin: localhost, where the page is 127.0.0.1.
            body = ("<!doctype html><title>embed</title><body style='margin:0'>"
                    f"<iframe id=frame allowfullscreen width=320 height=180 src='http://localhost:{port}/frame'></iframe>"
                    + WATCH.replace("TARGET", "'frame'"))
        elif self.path == "/frame":
            body = ("<!doctype html><title>frame</title><body style='margin:0'>"
                    "<div id=video style='width:100px;height:60px;background:#f80'></div>"
                    + WATCH.replace("TARGET", "'video'"))
        else:
            body = f"<!doctype html><title>{self.path.strip('/')}</title><p>{self.path}"
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"


def ev(tab, js):
    return sv.cmd({"do": "eval", "id": tab, "js": js})["value"]


def state():
    return sv.cmd({"do": "fillswindow"})


def page(path):
    tab = sv.sp("open", url=f"{BASE}/{path}")["resultID"]
    time.sleep(1.2)
    sv.sp("select", id=tab)
    time.sleep(0.6)
    return tab


def press_f(tab, frame=False):
    # Into the frame's document when asked: the key goes where focus is.
    ev(tab, "document.getElementById('frame').contentWindow.focus(); 1" if frame else "window.focus(); 1")
    sv.cmd({"do": "key", "id": tab, "text": "f"})
    time.sleep(1.4)


def esc():
    sv.cmd({"do": "press", "code": 53, "chars": ESC})
    time.sleep(1.0)


def fills_viewport(tab, element):
    return ev(tab, f"""(function () {{
      var r = document.getElementById('{element}').getBoundingClientRect();
      return r.left === 0 && r.top === 0 && r.width === innerWidth && r.height === innerHeight;
    }})()""")


def change_before_growth(log):
    """The first change in, and a resize after it to a bigger viewport."""
    for i, entry in enumerate(log):
        if entry[0] == "change" and entry[1]:
            width, height = entry[2], entry[3]
            return any(e[0] == "resize" and (e[1] > width or e[2] > height) for e in log[i + 1:])
    return False


def settings(on):
    sv.cmd({"do": "settings", "set": "fullscreen.inWindow", "value": on, "find": "full screen in the window"})
    time.sleep(0.8)


t = sv.T()
sv.setup(**{"sidebar": True, "fullscreen.inWindow": True, "fullscreen.escapeTwice": False})
sv.launch()
try:
    print("A window not in full screen")
    sv.cmd({"do": "fillswindow", "pretend": False})
    tab = page("player")
    press_f(tab)
    s = state()
    t.ok("the page's element is the full screen", ev(tab, "document.fullscreenElement && document.fullscreenElement.id") == "player")
    t.ok("it fills the viewport, out of its transformed parent", fills_viewport(tab, "player"))
    t.ok("the rest of the page is out of sight", ev(tab, "getComputedStyle(document.getElementById('after')).visibility") == "hidden")
    t.ok("the tab fills its window, its chrome aside", s["filling"] == [tab] and s["immersed"] == [tab], s)
    t.ok("the window is asked into full screen, once", s["windowFull"] and s["toggles"] == 1, s)
    t.ok("WebKit's own full screen is never used", ev(tab, "1") == 1 and not sv.cmd({"do": "probe"})["cards"]["windowFullScreen"])
    log = ev(tab, "JSON.stringify(__log)")
    t.ok("fullscreenchange comes before the viewport grows", change_before_growth(__import__("json").loads(log)), log)
    esc()
    s = state()
    t.ok("Escape ends it", ev(tab, "String(document.fullscreenElement)") == "null")
    t.ok("and the page never sees the Escape", "escape" not in ev(tab, "JSON.stringify(__log)"))
    t.ok("the window is asked out again, and the chrome is back", not s["windowFull"] and s["toggles"] == 2 and not s["filling"] and not s["immersed"], s)
    t.ok("the element's own style is as it was", ev(tab, "(function (s) { return s.width === '320px' && s.height === '180px' && !s.position && !s.zIndex && !s.inset; })(document.getElementById('player').style)"))

    print("A window already in full screen")
    sv.cmd({"do": "fillswindow", "pretend": True})
    ev(tab, "__log = []; 1")
    press_f(tab)
    s = state()
    t.ok("the page fills the window", s["filling"] == [tab] and fills_viewport(tab, "player"), s)
    t.ok("nothing is asked of the window", s["windowFull"] and s["toggles"] == 0, s)
    log = ev(tab, "JSON.stringify(__log)")
    t.ok("fullscreenchange still comes before the viewport grows", change_before_growth(__import__("json").loads(log)), log)
    esc()
    s = state()
    t.ok("Escape ends it, and the window stays in full screen", not s["filling"] and s["windowFull"] and s["toggles"] == 0, s)

    print("A player in a frame of another site")
    sv.cmd({"do": "fillswindow", "pretend": False})
    embed = page("embed")
    press_f(embed, frame=True)
    s = state()
    t.ok("the frame is the page's full screen, and fills it", ev(embed, "document.fullscreenElement && document.fullscreenElement.id") == "frame" and fills_viewport(embed, "frame"))
    t.ok("the tab fills its window", s["filling"] == [embed] and s["toggles"] == 1, s)
    esc()
    s = state()
    t.ok("Escape ends it in the page and in the frame",
         ev(embed, "String(document.fullscreenElement)") == "null" and not s["filling"] and s["toggles"] == 2, s)

    print("Another tab shown")
    sv.sp("select", id=tab)
    time.sleep(0.6)
    press_f(tab)
    t.ok("in again", state()["filling"] == [tab])
    sv.sp("select", id=embed)
    time.sleep(1.0)
    s = state()
    t.ok("it ends, and the window comes back", not s["filling"] and not s["windowFull"] and ev(tab, "String(document.fullscreenElement)") == "null", s)

    print("The switch, with the page up")
    sv.sp("select", id=tab)
    time.sleep(0.6)
    native = "Function.prototype.toString.call(Element.prototype.requestFullscreen).indexOf('[native code]') >= 0"
    settings(False)
    t.ok("off: the page has WebKit's own API back", ev(tab, native) and ev(tab, "typeof window.__searchFills") == "undefined")
    settings(True)
    t.ok("on again: Search's, without a reload", not ev(tab, native) and ev(tab, "window.__searchFills") is True)
    press_f(tab)
    t.ok("and it fills the window", state()["filling"] == [tab])
    esc()
finally:
    sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)
