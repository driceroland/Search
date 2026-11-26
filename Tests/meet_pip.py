#!/usr/bin/env python3
"""Google Meet's own little window (MeetPiP.swift), on a page that does what
Meet does, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/meet_pip.py`. The split
suite's harness: started hidden, nothing shown, removed afterwards. The
little window is made and driven but never put on screen in a test run
(MeetPiPWindow.shows); `meetpip state` says so and the run checks it.

The page stands in for Meet: it looks for documentPictureInPicture and a
Chrome navigator.userAgent, gives mediaSession an 'enterpictureinpicture'
handler, goes on a call with WebKit's pretend camera, and in its window
puts its tile — a <video> of a canvas's stream, moved over from the page —
a second video made there for the camera, as Meet makes its own, and two
buttons that call back into the page. The test host stands in for
meet.google.com (MeetPiP.testHostKey); "localhost", the same server, is
any other site.
"""
import json
import os
import subprocess
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("meet-pip")
t = sv.T()

CALL = r"""<!doctype html><title>call</title>
<style>body{margin:0;font:13px system-ui} #tile{width:320px;height:180px;background:#123}
#tile video{width:100%;height:100%} .bar button{margin:4px}</style>
<div id=home><div id=tile><video id=v autoplay playsinline muted></video></div></div>
<button id=pip>Picture in picture</button>
<script>
window.log = []; window.calls = {mute: 0, leave: 0}; window.closedPiP = 0; window.entered = 0;
window.has = {api: 'documentPictureInPicture' in window, chrome: / Chrome\/\d+/.test(navigator.userAgent)};
var c = document.createElement('canvas'); c.width = 320; c.height = 180;
var g = c.getContext('2d'), n = 0;
setInterval(function () { g.fillStyle = 'hsl(' + (n++ * 7 % 360) + ',70%,50%)'; g.fillRect(0, 0, 320, 180); }, 40);
var tile = document.getElementById('tile'), v = document.getElementById('v'); v.srcObject = c.captureStream(25); v.play();
window.state = 'starting';
navigator.mediaDevices.getUserMedia({video: true, audio: true}).then(function (s) {
  window.stream = s; window.state = 'started';
}, function (e) { window.state = 'error ' + e.name; });
function mute() { calls.mute++; if (window.stream) stream.getAudioTracks().forEach(function (t) { t.enabled = !t.enabled; }); }
function leave() { calls.leave++; if (window.pipWindow) pipWindow.close(); }
if (window.documentPictureInPicture) documentPictureInPicture.addEventListener('enter', function (e) { window.entered++; window.enterWindowOK = e.window === documentPictureInPicture.window; });
async function openPiP(why) {
  log.push('open ' + why);
  try {
    var w = await documentPictureInPicture.requestWindow({width: 300, height: 356});
    window.pipWindow = w;
    // The page's styles, as Meet copies its own.
    [].forEach.call(document.querySelectorAll('style'), function (s) { w.document.head.appendChild(s.cloneNode(true)); });
    w.document.body.appendChild(tile);
    var cam = w.document.createElement('video'); cam.id = 'cam'; cam.autoplay = true; cam.muted = true; cam.playsInline = true;
    cam.srcObject = window.stream || null; w.document.body.appendChild(cam); cam.play();
    var bar = w.document.createElement('div'); bar.className = 'bar';
    bar.innerHTML = '<button id=mute>Mute</button><button id=leave>Leave</button>';
    w.document.body.appendChild(bar);
    w.document.getElementById('mute').addEventListener('click', mute);
    w.document.getElementById('leave').addEventListener('click', leave);
    w.addEventListener('pagehide', function (e) {
      closedPiP++; window.pipWindow = null; log.push('pagehide ' + (e.isTrusted ? 'trusted' : 'shim'));
      document.getElementById('home').appendChild(tile);
      document.getElementById('v').play();
    });
    log.push('opened');
  } catch (e) { log.push('error ' + e.name); }
}
document.getElementById('pip').addEventListener('click', function () { openPiP('click'); });
navigator.mediaSession.setActionHandler('enterpictureinpicture', function (d) {
  if (window.hijack) { window.hijacked = String(!!window.open('/x2')); return; }
  openPiP('auto ' + (d && d.enterPictureInPictureReason)); });
</script>"""
PLAIN = "<!doctype html><title>other</title><p>other"


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = (CALL if self.path.startswith("/call") else PLAIN).encode()
        self.send_response(200); self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def log_message(self, *a): pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
sv.BASE = f"http://127.0.0.1:{srv.server_port}"
OTHER = f"http://localhost:{srv.server_port}"


def mp(action="state", **f): return sv.cmd({"do": "meetpip", "action": action, **f})
def pev(js, n=0): return mp("eval", js=js, n=n).get("value")


def until(cond, within=6):
    end = time.time() + within
    while time.time() < end:
        try:
            if cond(): return True
        except Exception:
            pass
        time.sleep(0.2)
    return cond()


def frames_advance(n=0):
    """The moved tile's video and the camera's, in the little window: not
    paused, time going on, and the picture changing — read back by drawing
    the video into a canvas there, since WebKit counts no decoded frames for
    a stream (getVideoPlaybackQuality says 0) and a page never shown paints
    nothing to count by requestVideoFrameCallback."""
    js = ("JSON.stringify(['v','cam'].map(function(id){var e=document.getElementById(id);"
          "if(!e)return null;var c=document.createElement('canvas');c.width=8;c.height=8;"
          "var g=c.getContext('2d');g.drawImage(e,0,0,8,8);var d=g.getImageData(4,4,1,1).data;"
          "return {paused:e.paused,t:e.currentTime,rs:e.readyState,w:e.videoWidth,px:[d[0],d[1],d[2]].join(',')}}))")
    a = json.loads(pev(js, n)); time.sleep(1.3); b = json.loads(pev(js, n))
    return a, b


def nothing_on_screen():
    return not mp()["visibleOnScreen"]


try:
    sv.setup(splitView=False)
    for kind in (0, 1, 2):
        subprocess.run(["defaults", "write", sv.SUITE, f"capture.{sv.BASE}|{kind}", "-bool", "true"])
    subprocess.run(["defaults", "write", sv.SUITE, "meetPiP.testHost", "127.0.0.1"])
    subprocess.run(["defaults", "write", sv.SUITE, "meet.pip", "-bool", "true"])
    sv.launch()

    st = mp()
    t.ok("the switch is on in this run", st["on"], st)
    call = sv.page("call")
    t.ok("the call starts", until(lambda: sv.ev(call, "window.state") == "started"), sv.ev(call, "window.state"))
    has = sv.ev(call, "JSON.stringify(has)")
    t.ok("the page finds documentPictureInPicture and a Chrome user agent", json.loads(has) == {"api": True, "chrome": True}, has)
    t.ok("its enterpictureinpicture handler reached Search", until(lambda: len(mp()["armed"]) == 1), mp())

    # Another tab in front during the call: Meet's window by itself (checked
    # in full below); back to the call, it goes.
    other = sv.page("x")
    t.ok("opening another tab during the call opens the window by itself", until(lambda: len(mp()["windows"]) == 1 and mp()["windows"][0]["auto"]), mp())
    sv.sp("select", id=call)
    t.ok("back to the call, it closes", until(lambda: mp()["windows"] == []), mp())
    t.ok("and the page heard pagehide, its tile back home", until(lambda: sv.ev(call, "closedPiP") == 1 and sv.ev(call, "!!document.querySelector('#home #tile')")), sv.ev(call, "JSON.stringify(log)"))
    # Another site, on the same server: none of it.
    sv.sp("open", url=f"{OTHER}/elsewhere"); time.sleep(1)
    tabs = sv.sp("state")["tabs"]
    elsewhere = next(x["id"] for x in tabs if x["url"].startswith(OTHER))
    plain = sv.ev(elsewhere, "JSON.stringify({api: 'documentPictureInPicture' in window, ua: navigator.userAgent})")
    p = json.loads(plain)
    t.ok("another site gets no shim and Search's own user agent", not p["api"] and " Chrome/" not in p["ua"], plain)
    sv.sp("select", id=call); time.sleep(1)

    # No click: refused, as Chrome refuses it without a gesture.
    sv.ev(call, "documentPictureInPicture.requestWindow({width:300,height:300}).then(function(){window.noClick='opened'},function(e){window.noClick=e.name}); 1")
    t.ok("without a click, requestWindow is refused (NotAllowedError)",
         until(lambda: sv.ev(call, "window.noClick") == "NotAllowedError"), sv.ev(call, "window.noClick"))
    t.ok("and no window was made", mp()["windows"] == [], mp())

    # 1. By hand: the page's own button, a real click.
    entered0 = sv.ev(call, "entered"); closed0 = sv.ev(call, "closedPiP")
    sv.cmd({"do": "tap", "id": call, "selector": "#pip"})
    t.ok("a click opens the little window", until(lambda: len(mp()["windows"]) == 1), mp())
    w = mp()["windows"][0] if mp()["windows"] else {}
    t.ok("it is a floating panel, for this tab, not opened by a switch",
         w.get("level") == 3 and not w.get("auto"), w)
    t.ok("it is never on screen in a test run", nothing_on_screen(), mp())
    t.ok("the page heard enter, with the window", until(lambda: sv.ev(call, "window.entered") == entered0 + 1 and sv.ev(call, "window.enterWindowOK")), sv.ev(call, "JSON.stringify([entered, enterWindowOK, log])"))
    t.ok("the page's tile moved into it", until(lambda: pev("!!document.querySelector('#tile video#v')")), pev("document.body.innerHTML.slice(0,300)"))
    t.ok("and left the page", sv.ev(call, "!document.getElementById('tile')"))
    t.ok("its styles came along", pev("getComputedStyle(document.getElementById('tile')).width") == "320px", pev("getComputedStyle(document.getElementById('tile')).width"))
    shot = mp("shot", path=f"/private/tmp/claude-501/meet-pip-shot-{os.getpid()}.png", width=300)
    t.ok("a picture of its page is drawn off screen, nothing shown", shot.get("width", 0) > 0 and os.path.getsize(shot["path"]) > 0 and nothing_on_screen(), shot)
    if shot.get("path"): os.remove(shot["path"])
    t.ok("same origin: the page reaches into it", sv.ev(call, "pipWindow.document.getElementById('mute') !== null"))
    a, b = frames_advance()
    t.ok("the moved video keeps playing (time goes on)", a[0] and b[0] and not b[0]["paused"] and b[0]["t"] > a[0]["t"] + 1, (a[0], b[0]))
    t.ok("the moved video's picture changes (new frames)", a[0] and b[0] and b[0]["px"] != a[0]["px"], (a[0], b[0]))
    t.ok("the camera video made there plays", a[1] and b[1] and not b[1]["paused"] and b[1]["t"] > a[1]["t"] + 1 and b[1]["w"] > 0, (a[1], b[1]))
    # Camera and microphone stay live while the window is open: WebKit must
    # neither end nor mute Meet's capture (setCameraActive/setMicrophoneActive).
    LIVE = ("JSON.stringify(stream.getTracks().map(function (k) {"
            " return {kind: k.kind, state: k.readyState, muted: k.muted, enabled: k.enabled, label: k.label}; }))")
    live0 = json.loads(sv.ev(call, LIVE) or "[]"); time.sleep(5)
    live1 = json.loads(sv.ev(call, LIVE) or "[]")
    t.ok("camera and microphone are WebKit's pretend ones", sorted(k["kind"] for k in live1) == ["audio", "video"]
         and all("Mock" in k["label"] or "mock" in k["label"].lower() for k in live1), live1)
    t.ok("camera and microphone stay live, unmuted and on, 5 s into the open window",
         len(live1) == 2 and all(k["state"] == "live" and not k["muted"] and k["enabled"] for k in live0 + live1)
         and len(mp()["windows"]) == 1, (live0, live1))
    mp("tap", selector="#mute")
    t.ok("a real click on its Mute calls the page's own function", until(lambda: sv.ev(call, "calls.mute") == 1), sv.ev(call, "JSON.stringify(calls)"))
    t.ok("which acted on the call (the microphone track off)", sv.ev(call, "stream.getAudioTracks()[0].enabled") is False)
    # Its page can't be sent elsewhere.
    pev("location.href = 'https://example.com/'; 1"); time.sleep(1)
    t.ok("its page can't go anywhere else", (mp()["windows"] or [{}])[0].get("url", "") in ("", "about:blank"), mp())
    mp("close")
    t.ok("its close button closes it", until(lambda: mp()["windows"] == []), mp())
    t.ok("the page heard pagehide and took its tile back",
         until(lambda: sv.ev(call, "closedPiP") == closed0 + 1 and sv.ev(call, "!!document.querySelector('#home #tile')")),
         sv.ev(call, "JSON.stringify([closedPiP, log])"))
    t.ok("documentPictureInPicture.window is null again", sv.ev(call, "documentPictureInPicture.window === null"))
    t.ok("the tile plays in the page again", until(lambda: sv.ev(call, "!document.getElementById('v').paused")))

    # 2. By itself: another tab in front during the call, as in Chrome.
    sv.sp("select", id=other)
    t.ok("going to another tab opens it by itself", until(lambda: len(mp()["windows"]) == 1), (mp(), sv.ev(call, "JSON.stringify(log)")))
    w = mp()["windows"][0] if mp()["windows"] else {}
    t.ok("marked as opened by the switch", w.get("auto") is True, w)
    t.ok("Meet's handler was called as Chrome's own button calls it (useraction)", "open auto useraction" in (sv.ev(call, "JSON.stringify(log)") or ""), sv.ev(call, "JSON.stringify(log)"))
    t.ok("Search's own floating video did not take the page", not sv.cmd({"do": "float", "action": "showing"})["showing"])
    t.ok("still nothing on screen", nothing_on_screen(), mp())
    a, b = frames_advance()
    t.ok("behind: the moved video keeps playing, new frames", a[0] and b[0] and b[0]["t"] > a[0]["t"] + 1 and b[0]["px"] != a[0]["px"], (a[0], b[0]))
    mp("tap", selector="#leave")
    t.ok("its Leave reaches the page, which closes it", until(lambda: sv.ev(call, "calls.leave") == 1 and mp()["windows"] == []), (sv.ev(call, "JSON.stringify(calls)"), mp()))
    sv.sp("select", id=call); time.sleep(1)
    sv.sp("select", id=other)
    t.ok("away again: it opens again", until(lambda: len(mp()["windows"]) == 1), mp())
    closed1 = sv.ev(call, "closedPiP")
    sv.sp("select", id=call)
    t.ok("back to the call: it closes by itself", until(lambda: mp()["windows"] == []), mp())
    t.ok("and the page heard pagehide", until(lambda: sv.ev(call, "closedPiP") == closed1 + 1), sv.ev(call, "JSON.stringify(log)"))

    # A window opened by hand stays when you come back, as in Chrome.
    sv.cmd({"do": "tap", "id": call, "selector": "#pip"})
    until(lambda: len(mp()["windows"]) == 1)
    sv.sp("select", id=other); time.sleep(1); sv.sp("select", id=call); time.sleep(1)
    t.ok("one opened by hand stays, and only one", len(mp()["windows"]) == 1 and not mp()["windows"][0]["auto"], mp())

    # Search's switch is good for Meet's window only: the handler opening
    # an ordinary pop-up with it gets nothing.
    mp("close"); until(lambda: mp()["windows"] == [])
    before = len(sv.sp("state")["tabs"])
    sv.ev(call, "window.hijack = true; 1")
    sv.sp("select", id=other)
    t.ok("the switch's grant opens no other window", until(lambda: sv.ev(call, "window.hijacked") == "false") and len(sv.sp("state")["tabs"]) == before,
         (sv.ev(call, "window.hijacked"), len(sv.sp("state")["tabs"]), before))
    sv.sp("select", id=call); time.sleep(0.5); sv.ev(call, "window.hijack = false; 1")

    # The call's tab closed: its window goes with it.
    sv.sp("select", id=other); until(lambda: len(mp()["windows"]) == 1)
    sv.sp("close", id=call)
    t.ok("closing the call's tab closes its window", until(lambda: mp()["windows"] == []), mp())
    t.ok("nothing was ever on screen", nothing_on_screen(), mp())
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
