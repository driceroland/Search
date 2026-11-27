#!/usr/bin/env python3
"""A large download that drops midway, then Retry and Resume (idea 1148), in
a hidden probe.

Build first (`./build.sh`), then `python3 Tests/download_retry.py`. A local
server sends a large .psd slowly, as an attachment, and closes the
connection halfway on its first attempt. The Downloads panel's row is read
and its own Retry and Resume called through ./bench (downloads-rows); the
server counts what was asked for, and the probe's Downloads folder is read
back. Nothing is drawn, nothing is brought forward.
"""
import os
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("download-retry")

SIZE = 8 * 1024 * 1024
BODY = bytes((i * 7) & 0xFF for i in range(SIZE))
CHUNK = 64 * 1024
LOG = []
DROPS = {"count": 0}
LOCK = threading.Lock()


class Slow(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        path = self.path.split("?")[0]
        rng = self.headers.get("Range")
        with LOCK:
            LOG.append((path, rng))
        if path == "/page":
            body = b"<!doctype html><title>page</title><a id=a href='/art.psd'>art</a><a id=b target=_blank href='/go'>art</a>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if path == "/go":
            # A signed link, as a site's download button hands out: a
            # redirect to the file itself.
            self.send_response(302)
            self.send_header("Location", "/art.psd")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if path not in ("/art.psd", "/norange.psd"):
            self.send_error(404)
            return
        ranges = path == "/art.psd"
        start = 0
        if rng and ranges and rng.startswith("bytes="):
            start = int(rng[6:].split("-")[0] or 0)
        self.send_response(206 if start else 200)
        self.send_header("Content-Type", "image/vnd.adobe.photoshop")
        self.send_header("Content-Disposition", 'attachment; filename="Magnific art.psd"')
        self.send_header("Content-Length", str(SIZE - start))
        self.send_header("ETag", '"art-1"')
        self.send_header("Last-Modified", "Tue, 24 Nov 2026 10:00:00 GMT")
        if ranges:
            self.send_header("Accept-Ranges", "bytes")
            if start:
                self.send_header("Content-Range", f"bytes {start}-{SIZE - 1}/{SIZE}")
        self.end_headers()
        # The first attempt from the start drops halfway, as the reporter's did.
        drop = False
        with LOCK:
            if start == 0 and DROPS["count"] < DROP_FIRST:
                DROPS["count"] += 1
                drop = True
        sent = start
        try:
            while sent < SIZE:
                if drop and sent >= SIZE // 2:
                    if STALL["on"]:
                        # Stalls instead: the connection stays, nothing comes.
                        time.sleep(STALL["for"])
                    self.connection.shutdown(2)
                    self.close_connection = True
                    return
                piece = BODY[sent:sent + CHUNK]
                self.wfile.write(piece)
                sent += len(piece)
                time.sleep(0.01)
        except (BrokenPipeError, ConnectionResetError, OSError):
            return

    def log_message(self, *a):
        pass


DROP_FIRST = 1
STALL = {"on": False, "for": 0}
srv = ThreadingHTTPServer(("127.0.0.1", 0), Slow)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"


def rows():
    return sv.cmd({"do": "downloads-rows"})


def downloads():
    folder = Path(sv.SUPPORT) / "Downloads"
    return sorted(p.name for p in folder.iterdir()) if folder.exists() else []


def wait(cond, within=60):
    end = time.time() + within
    while time.time() < end:
        r = rows()
        if cond(r):
            return r
        time.sleep(0.25)
    return rows()


def gets(path):
    with LOCK:
        return [r for p, r in LOG if p == path]


def fail_once(t, name, path):
    """Opens PATH, waits for its drop, and answers the failed row."""
    with LOCK:
        LOG.clear()
        DROPS["count"] = 0
    sv.sp("open", url=f"{BASE}/page")
    time.sleep(1)
    tid = sv.sp("state")["tabs"][-1]["id"]
    sv.ev(tid, f"location.href = '{path}'")
    r = wait(lambda r: r["rows"] and r["rows"][0]["state"] == "failed")
    t.ok(f"{name}: the drop leaves one failed row", len(r["rows"]) == 1 and r["rows"][0]["state"] == "failed", r)
    return r


def main():
    t = sv.T()
    try:
        sv.setup()
        sv.launch()

        # Retry: one download from the start, the failed row replaced.
        r = fail_once(t, "retry", "/art.psd")
        before = len(r["completed"])
        sv.cmd({"do": "downloads-rows", "press": "retry", "index": 0})
        r = wait(lambda r: not r["rows"], within=90)
        time.sleep(2)
        r = rows()
        files = downloads()
        asked = gets("/art.psd")
        t.ok("retry: no row left behind", not r["rows"], r)
        t.ok("retry: one file in the Completed list", len(r["completed"]) - before == 1, r["completed"])
        t.ok("retry: one file in Downloads", len([f for f in files if f.endswith(".psd")]) == 1, files)
        t.ok("retry: the server was asked twice in all (the drop, then the retry)", len(asked) == 2, asked)
        psd = [f for f in files if f.endswith(".psd")]
        if psd:
            t.ok("retry: the file is whole", (Path(sv.SUPPORT) / "Downloads" / psd[0]).stat().st_size == SIZE)
            for f in psd:
                (Path(sv.SUPPORT) / "Downloads" / f).unlink()

        # Resume: goes on from where it dropped, with a Range request.
        r = fail_once(t, "resume", "/art.psd")
        row = r["rows"][0]
        print("   after the drop:", {k: row[k] for k in ("canResume", "canRetry", "completed", "total", "error")})
        if row["canResume"]:
            sv.cmd({"do": "downloads-rows", "press": "resume", "index": 0})
            r = wait(lambda r: not r["rows"], within=90)
            time.sleep(2)
            r = rows()
            asked = gets("/art.psd")
            files = [f for f in downloads() if f.endswith(".psd")]
            t.ok("resume: no row left behind", not r["rows"], r)
            # The Completed list keeps one line a path: the retry's file had the same name.
            t.ok("resume: one file", len(files) == 1 and [c["name"] for c in r["completed"]].count(files[0] if files else "") == 1, (files, r["completed"]))
            t.ok("resume: asked for the rest with a Range", any(a and a.startswith("bytes=") and a != "bytes=0-" for a in asked), asked)
            if files:
                data = (Path(sv.SUPPORT) / "Downloads" / files[0]).read_bytes()
                t.ok("resume: the file is whole and right", data == BODY, len(data))
                for f in files:
                    (Path(sv.SUPPORT) / "Downloads" / f).unlink()
        else:
            print("   (WebKit gave no resume data for the dropped transfer)")

        # Retry from a signed link (a redirect), its page closed meanwhile:
        # asked with a view of its own, still one download.
        r = fail_once(t, "redirect", "/go")
        sv.sp("close", id=sv.sp("state")["tabs"][-1]["id"])
        sv.cmd({"do": "downloads-rows", "press": "retry", "index": 0})
        r = wait(lambda r: not r["rows"], within=90)
        time.sleep(2)
        files = [f for f in downloads() if f.endswith(".psd")]
        t.ok("redirect, page closed: retry makes one file, no row left", len(files) == 1 and not rows()["rows"], (files, rows()))
        t.ok("redirect, page closed: one request for the retry", gets("/art.psd").count(None) == 2, gets("/art.psd"))
        for f in files:
            (Path(sv.SUPPORT) / "Downloads" / f).unlink()

        # Resume where the server takes no ranges: WebKit starts over, and
        # the file is whole, not the second half appended to the first.
        r = fail_once(t, "no ranges", "/norange.psd")
        if r["rows"] and r["rows"][0]["canResume"]:
            sv.cmd({"do": "downloads-rows", "press": "resume", "index": 0})
            wait(lambda r: not r["rows"], within=90)
            time.sleep(2)
            files = [f for f in downloads() if f.endswith(".psd")]
            whole = len(files) == 1 and (Path(sv.SUPPORT) / "Downloads" / files[0]).read_bytes() == BODY
            t.ok("no ranges: resume gives one whole, right file", whole, files)
    finally:
        t.done()
        sv.finish()
        srv.shutdown()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
