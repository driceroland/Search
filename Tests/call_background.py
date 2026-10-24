#!/usr/bin/env python3
"""A call goes on in a tab behind, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/call_background.py`. It uses
the split suite's harness: started hidden, no window made or shown, removed
afterwards. The camera and microphone are WebKit's pretend ones (test runs
only, see ExtensionCapture.mockDevices); the page sends its camera to a
second connection of its own, as a call site sends it to the others, and
counts what goes out.

A page on a call is kept in the window, unseen, while another tab is in front
(StageView.calls): out of the window, WebKit treats it as a page nobody can
see, and a call site's own loop that hands the camera on stalled — the
others saw a frozen picture until you came back (Google Meet, 24 Oct 2026).
A hidden probe's window is never on screen, so what the page itself does
behind is the same here kept or not; what is checked is where the page is,
that frames keep going out, and that a tab with no call still leaves the
window. Whether Meet's picture keeps moving for the others is checked by
hand on a release candidate.
"""
import os
import subprocess
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bld-call")
t = sv.T()

CALL = r"""<!doctype html><title>call</title>
<style>html,body{margin:0;height:100%}</style>
<video id=v autoplay playsinline muted width=320 height=240></video><script>
window.ticks = {interval: 0, rvfc: 0}; window.clicks = 0;
addEventListener('mousedown', () => clicks++);
setInterval(() => ticks.interval++, 100);
window.state = 'starting';
(async () => {
  try {
    const stream = await navigator.mediaDevices.getUserMedia({video: true, audio: true});
    window.stream = stream;
    const v = document.getElementById('v'); v.srcObject = stream;
    (function f() { ticks.rvfc++; v.requestVideoFrameCallback(f); })();
    // The camera sent to a second connection, as to the others on a call.
    const a = new RTCPeerConnection(), b = new RTCPeerConnection();
    a.onicecandidate = e => e.candidate && b.addIceCandidate(e.candidate);
    b.onicecandidate = e => e.candidate && a.addIceCandidate(e.candidate);
    stream.getTracks().forEach(t => a.addTrack(t, stream));
    await a.setLocalDescription(await a.createOffer()); await b.setRemoteDescription(a.localDescription);
    await b.setLocalDescription(await b.createAnswer()); await a.setRemoteDescription(b.localDescription);
    window.pa = a; window.pb = b; window.state = 'started';
  } catch (e) { window.state = 'error ' + e.name + ' ' + e.message; }
})();
window.sample = () => {
  window.__s = null;
  Promise.all([pa.getStats(), pb.getStats()]).then(([sa, sb]) => {
    const o = {t: Date.now(), ticks: Object.assign({}, ticks)};
    sa.forEach(r => { if (r.type === 'outbound-rtp' && r.kind === 'video') o.sent = r.framesSent; });
    sb.forEach(r => { if (r.type === 'inbound-rtp' && r.kind === 'video') o.decoded = r.framesDecoded; });
    o.tracks = stream.getTracks().map(t => t.kind + ':' + t.readyState + (t.muted ? ':muted' : ''));
    window.__s = o;
  });
  return 1;
};
</script>"""
PLAIN = r"""<!doctype html><title>%s</title><style>html,body{margin:0;height:100%%}</style><script>
window.ticks = {interval: 0}; window.clicks = 0;
addEventListener('mousedown', () => clicks++);
setInterval(() => ticks.interval++, 100);
window.sample = () => { window.__s = {t: Date.now(), ticks: Object.assign({}, ticks)}; return 1; };
</script>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/")
        body = (CALL if name.startswith("call") else PLAIN % name).encode()
        self.send_response(200); self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def log_message(self, *a): pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
sv.BASE = f"http://127.0.0.1:{srv.server_port}"


def launch():
    """sv.launch, with SEARCH_MEASURE: hidden pages slowed as WebKit slows
    them in the shipped browser, which test runs otherwise turn off."""
    if os.path.exists(sv.SOCK): os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_MEASURE=1", sv.APP])
    for _ in range(150):
        if os.path.exists(sv.SOCK): break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update((sv.running() - before) & sv.holding())


def tab(id): return next(x for x in sv.sp("state")["tabs"] if x["id"] == id)


def sample(id):
    sv.ev(id, "sample()")
    for _ in range(30):
        time.sleep(0.1)
        s = sv.ev(id, "window.__s")
        if s: return s
    return None


def rates(id, secs=4):
    a = sample(id); time.sleep(secs); b = sample(id)
    dt = (b["t"] - a["t"]) / 1000
    out = {k: (b[k] - a[k]) / dt for k in ("sent", "decoded") if k in a and k in b}
    out.update({k: (b["ticks"][k] - a["ticks"][k]) / dt for k in a["ticks"]})
    out["tracks"] = b.get("tracks")
    return out


def until(cond, within=6):
    end = time.time() + within
    while time.time() < end:
        if cond(): return True
        time.sleep(0.2)
    return cond()


try:
    sv.setup(splitView=True)
    # The site's camera and microphone answered yes beforehand (Browser.askedForCapture).
    for kind in (0, 1, 2):
        subprocess.run(["defaults", "write", sv.SUITE, f"capture.{sv.BASE}|{kind}", "-bool", "true"])
    launch()

    idle = sv.page("idle")
    call = sv.page("call")
    t.ok("the call starts", until(lambda: sv.ev(call, "window.state") == "started"), sv.ev(call, "window.state"))
    t.ok("WebKit says the tab is on a call", until(lambda: tab(call)["onCall"]), tab(call))
    front = rates(call)
    t.ok("in front: the camera goes out", front.get("sent", 0) > 20, front)

    # The keys in the call's page, then another tab in front.
    sv.sp("keys", id=call)
    t.ok("the call's page has the keys", tab(call)["hasKeys"], tab(call))
    other = sv.page("other"); time.sleep(1)
    st = sv.sp("state")
    t.ok("another tab is in front", st["visibleIDs"] == [other], st["visibleIDs"])
    c = tab(call)
    t.ok("behind: the call's page stays in the window", c["inWindow"] and c["heldForCall"], c)
    t.ok("behind: the call's page no longer has the keys", not c["hasKeys"], c)
    behind = rates(call, 6)
    t.ok("behind: the camera still goes out", behind.get("sent", 0) > 20, behind)
    t.ok("behind: the far end still gets pictures", behind.get("decoded", 0) > 20, behind)
    # getTracks() gives the two in no fixed order.
    t.ok("behind: the tracks are live, not muted", sorted(behind["tracks"] or []) == ["audio:live", "video:live"], behind["tracks"])
    i = tab(idle)
    t.ok("a tab with no call leaves the window as before", not i["inWindow"] and not i["heldForCall"], i)
    quiet = rates(idle, 3)
    t.ok("and its timers are held back as before", quiet["interval"] < 2.5, quiet)

    # A click on the page in front reaches it, not the page kept under it:
    # straight to the view the window finds under the point ("view"), since
    # a hidden window hands a click through the app to no view.
    f = sv.frames(sv.sp("state")).get(other)
    if f:
        x, y = f["x"] + f["width"] / 2, f["y"] + f["height"] / 2
        sv.sp("mouse", points=[[x, y], [x, y]], to="view"); time.sleep(0.5)
        t.ok("a click lands on the page in front", sv.ev(other, "clicks") >= 1, sv.ev(other, "clicks"))
        t.ok("and never on the call kept under it", sv.ev(call, "clicks") == 0, sv.ev(call, "clicks"))
    else:
        t.ok("the page in front has a frame on the stage", False, sv.sp("state").get("paneFrames"))

    # Back to the call: seen again, still sending.
    sv.sp("select", id=call); time.sleep(1)
    st = sv.sp("state"); c = tab(call)
    t.ok("back: the call is in front", st["visibleIDs"] == [call], st["visibleIDs"])
    t.ok("back: no longer kept unseen", c["inWindow"] and not c["heldForCall"], c)
    t.ok("back: the tab left behind leaves the window", not tab(other)["inWindow"], tab(other))
    again = rates(call)
    t.ok("back: the camera goes out", again.get("sent", 0) > 20, again)
    f = sv.frames(sv.sp("state")).get(call)
    if f:
        x, y = f["x"] + f["width"] / 2, f["y"] + f["height"] / 2
        sv.sp("mouse", points=[[x, y], [x, y]], to="view"); time.sleep(0.5)
        t.ok("back: a click reaches the call's page", sv.ev(call, "clicks") >= 1, sv.ev(call, "clicks"))

    # The call ends while another tab is in front: the page leaves the window.
    sv.sp("select", id=other); time.sleep(1)
    t.ok("away again: kept", tab(call)["heldForCall"], tab(call))
    sv.ev(call, "stream.getTracks().forEach(t => t.stop()); pa.close(); pb.close(); 1")
    t.ok("call over behind: WebKit says so", until(lambda: not tab(call)["onCall"]), tab(call))
    t.ok("call over behind: the page leaves the window",
         until(lambda: not tab(call)["inWindow"] and not tab(call)["heldForCall"]), tab(call))
    st = sv.sp("state")
    t.ok("the page in front is still the one in front", st["visibleIDs"] == [other] and tab(other)["inWindow"], st["visibleIDs"])
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
