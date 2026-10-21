"""Two apps behind one host each wear their own icon, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/sub_path_icons.py`. A home
server's apps live at host/sonarr and host/radarr and declare different
icons; keeping icons by host alone gave every one of them whichever was
fetched first. Each page now keeps the icon it declared, and a page that
declares none borrows the nearest page of its own app.
"""
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402
from arc_icons import png  # noqa: E402

COLOURS = {"sonarr": (220, 40, 40), "radarr": (40, 90, 220)}


class Apps(BaseHTTPRequestHandler):
    def do_GET(self):
        app, _, rest = self.path.strip("/").partition("/")
        if app in COLOURS and rest == "icon.png":
            self.reply(png(COLOURS[app], side=32), "image/png")
        elif app in COLOURS and rest == "login":
            self.reply(f"<!doctype html><title>{app}</title><link rel=icon href='/{app}/icon.png'>".encode(), "text/html")
        elif app == "lidarr" and rest == "login":
            self.reply(b"<!doctype html><title>lidarr</title><link rel=icon href='/lidarr/icon.png'>", "text/html")
        elif app in COLOURS:
            self.reply(f"<!doctype html><title>{app} {rest}</title>".encode(), "text/html")
        else:
            self.send_response(404)
            self.end_headers()

    def reply(self, body, kind):
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a): pass


def icon(tab_id):
    for tab in sv.cmd({"do": "tabs"}).get("tabs", []):
        if tab["id"] == tab_id: return tab.get("icon", "")
    return ""


def wait(tab_id, want):
    for _ in range(50):
        if want(icon(tab_id)): return icon(tab_id)
        time.sleep(0.2)
    return icon(tab_id)


def reddish(c): return len(c) == 6 and int(c[0:2], 16) > int(c[4:6], 16)
def bluish(c): return len(c) == 6 and int(c[4:6], 16) > int(c[0:2], 16)
def greenish(c): return len(c) == 6 and int(c[2:4], 16) > max(int(c[0:2], 16), int(c[4:6], 16))


def main():
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Apps)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{srv.server_port}"
    t = sv.T()
    try:
        sv.setup()
        # Kept by host, as before pages were.
        folder = Path(f"{sv.SUPPORT}/icons")
        folder.mkdir(parents=True, exist_ok=True)
        (folder / f"127.0.0.1:{srv.server_port}.png").write_bytes(png((40, 200, 60), side=32))
        sv.launch()
        early = sv.cmd({"do": "open", "url": f"{base}/radarr/calendar"})["id"]
        time.sleep(2)
        t.ok("an icon kept by host before still stands for the site", greenish(icon(early)), icon(early))
        sonarr = sv.cmd({"do": "open", "url": f"{base}/sonarr/login"})["id"]
        t.ok("sonarr wears its own icon", reddish(wait(sonarr, reddish)), icon(sonarr))
        radarr = sv.cmd({"do": "open", "url": f"{base}/radarr/login"})["id"]
        t.ok("radarr, on the same host, wears its own", bluish(wait(radarr, bluish)), icon(radarr))
        time.sleep(1)
        t.ok("radarr's arriving left sonarr's tab alone", reddish(icon(sonarr)), icon(sonarr))
        other = sv.cmd({"do": "open", "url": f"{base}/sonarr/calendar"})["id"]
        time.sleep(2)
        t.ok("a sonarr page that declares nothing borrows sonarr's", reddish(icon(other)), icon(other))
        broken = sv.cmd({"do": "open", "url": f"{base}/lidarr/login"})["id"]
        time.sleep(2)
        # Only the icon kept by host before stands for the whole site.
        t.ok("an app whose icon fails wears no other app's", greenish(icon(broken)), icon(broken))

        pages = {}
        for _ in range(20):
            try:
                pages = json.loads(Path(f"{sv.SUPPORT}/icons/pages.json").read_text()).get(f"127.0.0.1:{srv.server_port}", {})
            except (OSError, ValueError):
                pass
            if "/sonarr/login" in pages and "/radarr/login" in pages: break
            time.sleep(0.25)
        light = {page: kept.get("light") or kept.get("dark") for page, kept in pages.items()}
        t.ok("each page is kept with an icon of its own",
             light.get("/sonarr/login") and light.get("/radarr/login")
             and light["/sonarr/login"] != light["/radarr/login"], pages)
    finally:
        t.done()
        sv.finish()
        srv.shutdown()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
