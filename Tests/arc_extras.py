"""byearc's "More Arc features": Developer Mode, screenshots in Downloads,
and a pin's glance (DevMode.swift, Screenshots.swift, PinPreview.swift).

Build first (`./build.sh`), then `python3 Tests/arc_extras.py`. A hidden
probe of its own world; nothing is shown, played or signed in to, and the
screenshots folder is one of the world's, never the Mac's own.
"""
import os
import plistlib
import subprocess
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("arc-extras")

ASKED = []  # (path, Cache-Control, Pragma) for every request


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        ASKED.append((self.path, self.headers.get("Cache-Control", ""), self.headers.get("Pragma", "")))
        if self.path.startswith("/mail"):
            body = b"<!doctype html><title>(3) Probe Mail</title><p>mail"
        else:
            body = b"<!doctype html><title>dev</title><p>local dev page"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Cache-Control", "max-age=3600")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a): pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
PORT = srv.server_port


def wait(check, within=10, every=0.2):
    end = time.time() + within
    while True:
        r = check()
        if r or time.time() > end: return r
        time.sleep(every)


def open_tab(url):
    tab = sv.cmd({"do": "open", "url": url})
    wait(lambda: not next((t for t in sv.cmd({"do": "tabs"})["tabs"] if t["id"] == tab["id"]), {}).get("loading", True), 10)
    time.sleep(0.5)
    return tab["id"]


def asked(path):
    return [a for a in ASKED if a[0] == path]


def screenshot(folder, name, marked):
    """As the Mac writes one: under a hidden name, marked, then renamed."""
    hidden = folder / ("." + name)
    hidden.write_bytes(b"\x89PNG\r\n\x1a\n")
    if marked is not None:
        value = plistlib.dumps(marked, fmt=plistlib.FMT_BINARY).hex()
        subprocess.run(["xattr", "-wx", "com.apple.metadata:kMDItemIsScreenCapture", value, str(hidden)], check=True)
    hidden.rename(folder / name)


def main():
    t = sv.T()
    try:
        sv.setup(**{"developer.local": True, "downloads.screenshots": True})
        shots = Path(sv.SUPPORT) / "Screenshots"
        shots.mkdir(parents=True)
        subprocess.run(["defaults", "write", sv.SUITE, "downloads.screenshots.folder", "-string", str(shots)], check=True)
        # Already there before: never listed.
        screenshot(shots, "Screenshot 2026-11-25 at 08.00.00.png", True)
        sv.launch()

        # --- Developer Mode -------------------------------------------------
        local = open_tab(f"http://127.0.0.1:{PORT}/dev")
        r = sv.cmd({"do": "devmode", "id": local})
        t.ok("dev: on by itself for 127.0.0.1", r["on"] and r["local"], r)
        t.ok("dev: the command exists", r["command"], r)
        named = open_tab(f"http://localhost:{PORT}/dev?x=1")
        t.ok("dev: on by itself for localhost", sv.cmd({"do": "devmode", "id": named})["on"])

        r = sv.cmd({"do": "devmode", "id": local, "set": False})
        t.ok("dev: off by hand, kept for the site", not r["on"] and r["sites"] == {"127.0.0.1": False}, r)
        r = sv.cmd({"do": "devmode", "id": local, "toggle": True})
        t.ok("dev: the command turns it back on, nothing kept", r["on"] and r["sites"] == {}, r)

        before = len(asked("/dev"))
        sv.cmd({"do": "devmode", "id": local, "reload": True})
        wait(lambda: len(asked("/dev")) > before, 5)
        plain = asked("/dev")[before:]
        t.ok("dev: a plain reload asks the server", len(plain) == 1, plain)
        t.ok("dev: … without no-cache", plain and "no-cache" not in plain[0][1] + plain[0][2], plain)

        r = sv.cmd({"do": "devmode", "id": local, "cache": True})
        t.ok("dev: cache off for the site", r["cacheOff"], r)
        before = len(asked("/dev"))
        sv.cmd({"do": "devmode", "id": local, "reload": True})
        wait(lambda: len(asked("/dev")) > before, 5)
        fresh = asked("/dev")[before:]
        t.ok("dev: with the cache off, ⌘R's reload skips it (no-cache)",
             fresh and "no-cache" in fresh[0][1] + fresh[0][2], fresh)
        sv.cmd({"do": "devmode", "id": local, "cache": False})

        # --- Screenshots in Downloads ---------------------------------------
        r = wait(lambda: (lambda s: s if s["folder"] else None)(sv.cmd({"do": "screenshots"})), 5)
        t.ok("shots: watching the world's folder, not refused",
             r and Path(r["folder"]).resolve() == shots.resolve() and not r["refused"], r)
        screenshot(shots, "Screenshot 2026-11-25 at 23.00.00.png", True)
        screenshot(shots, "holiday.png", None)
        screenshot(shots, "Screenshot 2026-11-25 at 23.01.00.png", False)
        r = wait(lambda: (lambda s: s if any(c["name"].endswith("23.00.00.png") for c in s["completed"]) else None)(
            sv.cmd({"do": "screenshots"})), 5) or sv.cmd({"do": "screenshots"})
        names = [c["name"] for c in r["completed"]]
        time.sleep(0.8)
        names = [c["name"] for c in sv.cmd({"do": "screenshots"})["completed"]]
        t.ok("shots: the new screenshot is listed", "Screenshot 2026-11-25 at 23.00.00.png" in names, names)
        t.ok("shots: … as a Screenshot", any(c["from"] == "Screenshot" for c in r["completed"]), r["completed"])
        t.ok("shots: nothing else (old one, other picture, one marked not a capture)", len(names) == 1, names)
        r = sv.cmd({"do": "screenshots", "set": False})
        screenshot(shots, "Screenshot 2026-11-25 at 23.05.00.png", True)
        time.sleep(1)
        names = [c["name"] for c in sv.cmd({"do": "screenshots"})["completed"]]
        t.ok("shots: off, nothing more", len(names) == 1 and not r["on"], names)

        # --- A pin's glance -------------------------------------------------
        # An ordinary tab, not a bench one: bench tabs never sleep.
        mail = sv.sp("open", url=f"http://127.0.0.1:{PORT}/mail")["resultID"]
        time.sleep(2)
        sv.cmd({"do": "pin", "id": mail})
        sv.cmd({"do": "select", "id": local})
        r = sv.cmd({"do": "pinpreview", "id": mail})
        t.ok("pin: on by default", r["on"], r)
        t.ok("pin: the unread count from its title", r["unread"] == "3", r)
        t.ok("pin: no card while the window isn't in front (hidden probe)", r["refusal"] == "window not in front" and not r["shown"], r)
        r = sv.cmd({"do": "pinpreview", "id": mail, "picture": True})
        print("   live pin's picture:", r.get("picture") or "(none: a hidden window paints nothing)")
        # A pin in the space on screen stays awake; one asleep is one put to
        # sleep before it was pinned (or brought back at launch, unopened).
        sv.cmd({"do": "pin", "id": mail, "off": True})
        sv.cmd({"do": "select", "id": local})
        s = sv.cmd({"do": "sleep", "id": mail})
        sv.cmd({"do": "pin", "id": mail})
        s = sv.cmd({"do": "pinpreview", "id": mail})
        t.ok("pin: asleep, as a pin", s["asleep"] and not s["built"], s)
        r = sv.cmd({"do": "pinpreview", "id": mail, "picture": True, "hover": True})
        time.sleep(1)
        after = sv.cmd({"do": "pinpreview", "id": mail})
        t.ok("pin: asleep, asking for its glance doesn't wake it",
             r["asleepAfter"] and not r["builtAfter"] and after["asleep"] and not after["built"], (r, after))
        t.ok("pin: asleep, no unread count (it may be stale)", after["unread"] == "", after)
        t.ok("pin: hovered in a hidden probe, no card", not after["shown"], after)
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
