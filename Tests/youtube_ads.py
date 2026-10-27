#!/usr/bin/env python3
"""YouTube's ads taken out of the player's data (YouTubeAds.swift), on a
local stand-in for YouTube, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/youtube_ads.py`. It runs in
a world of its own (bld-yt-<checkout>) with split_view.py's harness: started
hidden, everything removed afterwards. The test settings make 127.0.0.1 one
of YouTube's hosts for the run (`test.youtubeHosts`); localhost, the same
server under another name, is "another site".

The stand-in page does what YouTube's does: its player data arrives as an
inline `var ytInitialPlayerResponse = {…}`, then from /youtubei/v1/player
through fetch, read with json() and with text() + JSON.parse. Each carries
adPlacements, playerAds, adSlots and adBreakHeartbeatParams beside the
video's own data.
"""
import json
import subprocess
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bld-yt")

PLAYER = {
    "responseContext": {"serviceTrackingParams": []},
    "playabilityStatus": {"status": "OK"},
    "streamingData": {"formats": [{"itag": 18, "url": "https://example.invalid/v"}]},
    "videoDetails": {"videoId": "fixture", "lengthSeconds": "212"},
    "adPlacements": [{"adPlacementRenderer": {"config": {}}}],
    "playerAds": [{"playerLegacyDesktopWatchAdsRenderer": {}}],
    "adSlots": [{"adSlotRenderer": {}}],
    "adBreakHeartbeatParams": "Q0FB",
}
ADS = ["adPlacements", "playerAds", "adSlots", "adBreakHeartbeatParams"]

# What the page reports: the keys of each of its three answers.
REPORT = """
<script>
function keys(o) { return Object.keys(o).sort().join(','); }
window.__yt = { inline: keys(window.ytInitialPlayerResponse) };
fetch('/youtubei/v1/player', { method: 'POST', body: '{}' }).then(function (r) { return r.json(); })
  .then(function (o) { window.__yt.json = keys(o); window.__yt.itag = o.streamingData.formats[0].itag; });
fetch('/youtubei/v1/player', { method: 'POST', body: '{}' }).then(function (r) { return r.text(); })
  .then(function (t) { window.__yt.text = keys(JSON.parse(t)); });
// Somebody else's JSON with the same key names stays as it is.
window.__yt.own = keys(JSON.parse('{"adSlots":[1],"mine":true}'));
if (parent !== window) setTimeout(function () { parent.postMessage(window.__yt, '*'); }, 800);
</script>"""


class H(BaseHTTPRequestHandler):
    def reply(self, body, kind="text/html"):
        body = body.encode()
        self.send_response(200); self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def do_GET(self):
        port = self.server.server_port
        if self.path == "/watch":
            self.reply(f"<!doctype html><title>watch</title><script>var ytInitialPlayerResponse = {json.dumps(PLAYER)};</script>{REPORT}")
        elif self.path == "/embedder":
            # Another site framing YouTube's player, as an embed does.
            self.reply(f"""<!doctype html><title>embedder</title>
<script>addEventListener('message', function (e) {{ window.__frame = e.data; }});</script>
<iframe src="http://127.0.0.1:{port}/watch"></iframe>""")
        else:
            self.send_response(404); self.end_headers()

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self.reply(json.dumps(PLAYER), "application/json")

    def log_message(self, *a): pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
PORT = srv.server_port
FULL = ",".join(sorted(PLAYER))
CLEAN = ",".join(sorted(k for k in PLAYER if k not in ADS))


def start(shield=True, paused=None):
    sv.setup(shield=shield)
    subprocess.run(["defaults", "write", sv.SUITE, "test.youtubeHosts", "-array", "127.0.0.1"], check=True)
    if paused:
        subprocess.run(["defaults", "write", sv.SUITE, "shield.paused", "-array", paused], check=True)
    sv.launch()


def visit(url, read="window.__yt", ready=lambda v: v and "json" in v and "text" in v):
    id = sv.cmd({"do": "open", "url": url})["id"]
    got = None
    for _ in range(30):
        time.sleep(0.4)
        got = sv.ev(id, read)
        if ready(got): break
    return got or {}


def visible_windows():
    """How many of this probe's windows are on a screen: there must never be
    one. Read from the window server, not from the app."""
    pids = sv.pids()
    if not pids: return 0
    js = f"""ObjC.import('CoreGraphics');
var a = ObjC.castRefToObject($.CGWindowListCopyWindowInfo(1, 0)), n = 0, pids = {json.dumps(pids)};
for (var i = 0; i < a.count; i++) {{ var w = a.objectAtIndex(i);
  if (pids.indexOf(String(ObjC.unwrap(w.objectForKey('kCGWindowOwnerPID')))) >= 0) n++; }}
n"""
    r = subprocess.run(["osascript", "-l", "JavaScript", "-e", js], capture_output=True, text=True)
    return int(r.stdout.strip() or -1)


t = sv.T()
try:
    start()
    yt = visit(f"http://127.0.0.1:{PORT}/watch")
    t.ok("inline ytInitialPlayerResponse: ads out, video data in", yt.get("inline") == CLEAN, yt)
    t.ok("/youtubei/v1/player read with json(): ads out", yt.get("json") == CLEAN, yt)
    t.ok("/youtubei/v1/player read with text() + JSON.parse: ads out", yt.get("text") == CLEAN, yt)
    t.ok("the player's formats are intact", yt.get("itag") == 18, yt)
    t.ok("another shape with the same key names is left alone", yt.get("own") == "adSlots,mine", yt)
    other = visit(f"http://localhost:{PORT}/watch")
    t.ok("another site: untouched", other.get("inline") == FULL and other.get("json") == FULL, other)
    framed = visit(f"http://localhost:{PORT}/embedder", read="window.__frame",
                   ready=lambda v: v and "json" in v and "text" in v)
    t.ok("YouTube's player framed in another site: ads out in the frame", framed.get("json") == CLEAN
         and framed.get("inline") == CLEAN, framed)
    t.ok("no window on a screen", visible_windows() == 0)
    sv.quit()

    start(shield=False)
    off = visit(f"http://127.0.0.1:{PORT}/watch")
    t.ok("Shield off: untouched", off.get("inline") == FULL and off.get("json") == FULL and off.get("text") == FULL, off)
    sv.quit()

    start(paused="127.0.0.1")
    paused = visit(f"http://127.0.0.1:{PORT}/watch")
    t.ok("Shield paused on the site: untouched", paused.get("inline") == FULL and paused.get("json") == FULL, paused)
    t.ok("no window on a screen", visible_windows() == 0)
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
