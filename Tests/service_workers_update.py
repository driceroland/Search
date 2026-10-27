#!/usr/bin/env python3
"""An update keeps the sites' service workers when no extension is installed.

Build first (`./build.sh`), then `python3 Tests/service_workers_update.py`.
A hidden probe in a world of its own, removed afterwards.

At launch, Search clears every service worker registration when what the
extensions' workers would run has changed (Extensions.forgetWorkersIfChanged,
#266): WebKit may otherwise start a stale copy of an extension's worker.
That list carries the shim's version, which changes with nearly every
update, so every update also cost everyone the workers of every site —
Google Docs, Gmail, X, YouTube — even with no extension at all (idea 446).

- no extension: a site's worker is still registered after a launch that
  finds the list changed (as after an update);
- with an extension installed: it is cleared at such a launch, as before.
"""
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("sw-update")


def running():
    """This build's probes, from one listing rather than pgrep."""
    out = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
    return {line.split(None, 1)[0] for line in out.splitlines() if sv.APP + "/Contents/MacOS" in line}


sv.running = running
PORT = sv.srv.server_port
BASE = f"http://127.0.0.1:{PORT}"


class Pages(sv.H):
    def do_GET(self):
        if self.path.startswith("/sw.js"):
            body, kind = b"self.addEventListener('fetch', () => {});", "text/javascript"
        elif self.path.startswith("/sw-page"):
            body, kind = b"<!doctype html><title>sw</title><script>navigator.serviceWorker.register('/sw.js')</script>", "text/html"
        else:
            return super().do_GET()
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


sv.srv.RequestHandlerClass = Pages


def registrations():
    """How many service workers the site has registered, from a page of its own."""
    before = {t["id"] for t in sv.cmd({"do": "tabs"})["tabs"]}
    sv.cmd({"do": "open", "url": f"{BASE}/plain"})
    time.sleep(1.5)
    tab = [t for t in sv.cmd({"do": "tabs"})["tabs"] if t["id"] not in before][-1]
    sv.ev(tab["id"], "window.__n = null; navigator.serviceWorker.getRegistrations().then((r) => window.__n = r.length); 1")
    count = None
    for _ in range(20):
        time.sleep(0.25)
        count = sv.ev(tab["id"], "window.__n")
        if count is not None:
            break
    sv.cmd({"do": "close", "id": tab["id"]})
    return count


def register():
    before = {t["id"] for t in sv.cmd({"do": "tabs"})["tabs"]}
    sv.cmd({"do": "open", "url": f"{BASE}/sw-page"})
    time.sleep(2)
    tab = [t for t in sv.cmd({"do": "tabs"})["tabs"] if t["id"] not in before][-1]
    sv.cmd({"do": "close", "id": tab["id"]})
    return registrations()


def as_after_an_update():
    """Relaunch with the extensions' list as an older build left it."""
    sv.quit()
    time.sleep(1)
    subprocess.run(["defaults", "write", sv.SUITE, "extensions.workers", "-string", "an older build"], check=True)
    sv.launch()
    time.sleep(2)


def main():
    t = sv.T()
    work = Path(tempfile.mkdtemp(prefix="search-sw-"))
    try:
        sv.setup()
        sv.launch()
        t.ok("a site registers its worker", register() == 1)
        as_after_an_update()
        t.ok("no extension: the site's worker is still there after an update", registrations() == 1)

        folder = work / "plain"
        folder.mkdir()
        (folder / "manifest.json").write_text(json.dumps({"manifest_version": 3, "name": "Plain", "version": "1.0"}))
        sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
        for _ in range(40):
            if any(x["name"] == "Plain" and x["loaded"] for x in sv.cmd({"do": "extensions"})["extensions"]):
                break
            time.sleep(0.5)
        t.ok("still there once an extension is put in", registrations() == 1)
        as_after_an_update()
        t.ok("with an extension: cleared after an update, as before (#266)", registrations() == 0)
    finally:
        sv.finish()
        subprocess.run(["rm", "-rf", str(work)])
    return t


if __name__ == "__main__":
    t = main()
    t.done()
    sys.exit(1 if t.failed else 0)
