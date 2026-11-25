#!/usr/bin/env python3
"""A video file opened as a page plays, checked in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/media_document.py`. Needs
ffmpeg to make the test video. The app starts hidden in a world of its own
(see split_view.use), is driven through ./bench's socket with trusted
clicks (`tap`), and is quit; its world is removed afterwards. Local pages
only.

A download site's "Download 1920x1080: mp4" link opens the .mp4 itself in
a new tab, on another site (video.twimg.com). WebKit shows a file like that
in its own player, and ends the page's load with "Plug-in handled load"
(WebKitErrorDomain 204), which is how that looks, not a failure. Search
took it for one and covered the playing video with "The page didn't load"
(18 Oct 2026). A file the server calls an attachment still downloads, and
a video that truly can't be reached still says so.
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("media-tests")

LINK = 'style="display:block;font-size:60px;line-height:120px;padding:0 20px"'
VIDEO = b""
# A port nothing listens on (not one WebKit refuses outright, as it does 1).
with socket.socket() as spare:
    spare.bind(("127.0.0.1", 0))
    CLOSED = spare.getsockname()[1]


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        page = urlparse(self.path).path
        if page.endswith(".mp4"):
            self.video(page)
            return
        # The page with the link, at 127.0.0.1; the video at localhost: a
        # link to another site, as twittervideodownloader.com's is.
        port = self.server.server_port
        to = page.strip("/")
        if to == "nowhere":
            href = f"http://localhost:{CLOSED}/gone.mp4"
        else:
            href = f"http://localhost:{port}/{to}.mp4"
        body = f'<!doctype html><meta charset=utf-8><a id="go" target="_blank" href="{href}" {LINK}>Download</a>'
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def video(self, page):
        ranges = page != "/norange.mp4"
        start, end = 0, len(VIDEO) - 1
        header = self.headers.get("Range", "")
        partial = ranges and header.startswith("bytes=")
        if partial:
            first, _, last = header[6:].partition("-")
            start = int(first or 0)
            end = min(int(last), end) if last else end
        chunk = VIDEO[start:end + 1]
        self.send_response(206 if partial else 200)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Content-Length", str(len(chunk)))
        if ranges:
            self.send_header("Accept-Ranges", "bytes")
        if partial:
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(VIDEO)}")
        if page == "/attach.mp4":
            self.send_header("Content-Disposition", 'attachment; filename="media-test-attach.mp4"')
        self.end_headers()
        try:
            self.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *args):
        pass


sv.srv.RequestHandlerClass = H


def tabs():
    return sv.cmd({"do": "tabs"})["tabs"]


def opened(before, wait=3.0):
    time.sleep(wait)
    ids = {t["id"] for t in before}
    return [t for t in tabs() if t["id"] not in ids]


def video_state(tab):
    return sv.ev(tab, "(() => { const v = document.querySelector('video'); return v ? "
                      "JSON.stringify({ready: v.readyState, time: v.currentTime, paused: v.paused, "
                      "error: v.error && v.error.code}) : 'none' })()")


def failure(tab):
    # The bench says "" for no failure since fdc43d31 (it said nothing before).
    return sv.cmd({"do": "wait", "id": tab, "seconds": 8}).get("failure") or None


def plays(t, name, path):
    page = sv.page(path)
    before = tabs()
    sv.cmd({"do": "tap", "id": page, "selector": "#go"})
    new = opened(before)
    t.ok(f"{name}: one new tab, on the video", [urlparse(x["url"]).path for x in new] == [f"/{path}.mp4"],
         [x["url"] for x in new])
    if len(new) != 1:
        return
    tab = new[0]["id"]
    # Started by a click: WebKit's player plays it at once.
    first = video_state(tab)
    time.sleep(1.5)
    later = video_state(tab)
    a = json.loads(first) if first and first != "none" else {}
    b = json.loads(later) if later and later != "none" else {}
    t.ok(f"{name}: the video is there and ready", b.get("ready", 0) >= 2 and not b.get("error"), later)
    if b.get("paused"):
        # A hidden probe may hold back playback; start it as the play button would.
        sv.ev(tab, "document.querySelector('video').play(), 1")
        time.sleep(0.3)
        a = json.loads(video_state(tab))
        time.sleep(1.5)
        b = json.loads(video_state(tab))
    t.ok(f"{name}: it plays", b.get("time", 0) > a.get("time", 0), (first, later, b))
    t.ok(f"{name}: no error page over it", failure(tab) is None, failure(tab))
    state = next((x for x in tabs() if x["id"] == tab), {})
    t.ok(f"{name}: the tab has stopped loading", state.get("loading") is False, state)


def main():
    global VIDEO
    ffmpeg = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"
    if not os.path.exists(ffmpeg):
        sys.exit("Tests/media_document.py needs ffmpeg to make its test video")
    with tempfile.TemporaryDirectory() as folder:
        out = f"{folder}/v.mp4"
        subprocess.run([ffmpeg, "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=640x360:rate=30",
                        "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo", "-t", "8", "-c:v", "libx264",
                        "-pix_fmt", "yuv420p", "-c:a", "aac", "-movflags", "+faststart", out], check=True)
        VIDEO = Path(out).read_bytes()
    # A test run downloads into its world's folder, removed with it.
    gone = lambda: sorted((Path(sv.SUPPORT) / "Downloads").glob("media-test-attach*.mp4"))
    t = sv.T()
    try:
        sv.setup(); sv.launch()
        plays(t, "an .mp4 on another site", "v")
        plays(t, "an .mp4 from a server without ranges", "norange")

        # An attachment is a download, as before: no tab left on it.
        page = sv.page("attach")
        before = tabs()
        sv.cmd({"do": "tap", "id": page, "selector": "#go"})
        new = opened(before, wait=4)
        t.ok("attachment: downloaded", len(gone()) == 1, [str(f) for f in gone()])
        t.ok("attachment: no tab left on it", not any(urlparse(x["url"]).path == "/attach.mp4" for x in new),
             [x["url"] for x in new])

        # A video that can't be reached still says so.
        page = sv.page("nowhere")
        before = tabs()
        sv.cmd({"do": "tap", "id": page, "selector": "#go"})
        new = opened(before)
        t.ok("unreachable: one new tab", len(new) == 1, [x["url"] for x in new])
        if new:
            t.ok("unreachable: the error page", failure(new[0]["id"]) is not None, new)
    finally:
        t.done(); sv.finish()
    return 1 if t.failed else 0


if __name__ == "__main__":
    if sys.platform != "darwin":
        sys.exit("Tests/media_document.py requires macOS and a built Search.app")
    sys.exit(main())
