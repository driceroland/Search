#!/usr/bin/env python3
"""An extension's content scripts run once per page, and chrome.identity
carries Chrome's AccountStatus (idea 1101, Fathom over Google Meet).

Build first (`./build.sh` or `./build.sh debug`), then run
`python3 Tests/extension_copies.py`. A hidden probe world of its own
(SEARCH_PROBE=ext-copies) installs a small unpacked extension shaped like
Fathom's: one isolated content script at document_idle and one in the
page's own world at document_start, on a local page shaped like a Meet
lobby that turns into a call the way Meet does — pushState, a new title, a
new favicon, the call's controls and an iframe. Each script counts its runs
on the page; each must have run once. The worker answers with
getProfileUserInfo({ accountStatus: AccountStatus.ANY }), which Fathom asks
before every request it makes. Nothing here makes, shows or brings forward
a window; the world's files and settings are removed afterwards.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = str(ROOT / "build" / "Search.app")
W = "ext-copies"
SUPPORT = os.path.expanduser(f"~/Library/Application Support/Search ({W})")
SUITE = f"com.officecommun.search.test.{W}"

MANIFEST = {
    "manifest_version": 3, "name": "Copies probe", "version": "1.0", "description": "Counts its content scripts.",
    "permissions": ["identity"], "host_permissions": ["http://127.0.0.1/*"],
    "background": {"service_worker": "sw.js"},
    "content_scripts": [
        {"matches": ["http://127.0.0.1/*"], "js": ["cs.js"]},
        {"matches": ["http://127.0.0.1/*"], "js": ["main.js"], "world": "MAIN", "run_at": "document_start"},
    ],
}
WORKER = """chrome.runtime.onMessage.addListener((m, sender, reply) => {
  if (!m || !m.identity) return;
  (async () => {
    try {
      const status = chrome.identity.AccountStatus;
      const info = await chrome.identity.getProfileUserInfo({ accountStatus: status.ANY });
      reply({ any: status.ANY, sync: status.SYNC, info });
    } catch (e) { reply({ error: String(e && e.message || e) }); }
  })();
  return true;
});"""
CONTENT = """(function () {
  var d = document.documentElement;
  d.dataset.isolated = (+d.dataset.isolated || 0) + 1;
  var ask = function () {
    chrome.runtime.sendMessage({ identity: true }).then(
      function (r) { d.dataset.identity = JSON.stringify(r); },
      function (e) { d.dataset.identity = JSON.stringify({ error: e.message }); });
  };
  window.addEventListener("copies-ask", ask);
  ask();
})();"""
MAIN = "document.documentElement.dataset.main = (+document.documentElement.dataset.main || 0) + 1;"
PAGE = b"""<!doctype html><meta charset=utf-8><title>Lobby</title><link rel=icon href="/one.png">
<div id=app><button>Join now</button></div>
<script>
function join() {
  history.pushState({}, "", location.pathname + "?authuser=0");
  document.title = "Call";
  document.querySelector("link[rel=icon]").href = "/two.png";
  document.getElementById("app").innerHTML = '<div aria-label="Call controls"><div id="browser-extension-center-buttons"></div>'
    + '<button aria-label="Leave call">Leave</button></div><iframe src="/frame"></iframe>';
}
</script>"""


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.endswith(".png"): body, kind = b"", "image/png"
        elif self.path.startswith("/frame"): body, kind = b"<!doctype html><p>frame", "text/html"
        else: body, kind = PAGE, "text/html"
        self.send_response(200); self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def log_message(self, *a):
        pass


def pids():
    return subprocess.run(["pgrep", "-f", APP + "/Contents/MacOS"], capture_output=True, text=True).stdout.split()


def bench(*args):
    out = subprocess.run([str(ROOT / "bench"), "--world", W, *args], capture_output=True, text=True, timeout=120)
    return out.stdout.strip()


def wipe():
    shutil.rmtree(SUPPORT, ignore_errors=True)
    subprocess.run(["defaults", "delete", SUITE], capture_output=True)


def dataset(tab, frame=False):
    js = ("JSON.stringify(Object.assign({}, document.querySelector('iframe').contentDocument.documentElement.dataset))"
          if frame else "JSON.stringify(Object.assign({}, document.documentElement.dataset))")
    return json.loads(bench("eval", tab, js) or "{}")


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    folder = tempfile.mkdtemp(prefix="search-ext-copies-")
    Path(folder, "manifest.json").write_text(json.dumps(MANIFEST))
    Path(folder, "sw.js").write_text(WORKER)
    Path(folder, "cs.js").write_text(CONTENT)
    Path(folder, "main.js").write_text(MAIN)
    passed = failed = 0

    def ok(name, cond, extra=""):
        nonlocal passed, failed
        if cond: passed += 1; print("  ok  ", name)
        else: failed += 1; print("  FAIL", name, extra)

    if pids(): sys.exit("another build/Search.app runs: quit it first")
    wipe()
    for key in ["bench", "welcomed"]:
        subprocess.run(["defaults", "write", SUITE, key, "-bool", "true"])
    sock = f"{SUPPORT}/bench.sock"
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={W}", APP])
    try:
        for _ in range(150):
            if os.path.exists(sock): break
            time.sleep(0.1)
        time.sleep(2)
        bench("ext-folder", folder, "--yes")
        time.sleep(3)
        tab = bench("open", f"http://127.0.0.1:{server.server_port}/abc-defg-hij")
        time.sleep(3)
        first = dataset(tab)
        ok("lobby: each content script ran once", first.get("isolated") == "1" and first.get("main") == "1", first)
        bench("eval", tab, "join(); 1")
        time.sleep(3)
        call = dataset(tab)
        ok("call (pushState, title, favicon, controls): still once each",
           call.get("isolated") == "1" and call.get("main") == "1", call)
        frame = dataset(tab, frame=True)
        ok("the call's iframe gets none (not all_frames)", "isolated" not in frame and "main" not in frame, frame)
        # The worker's first start can take a while in a new world.
        for _ in range(10):
            if call.get("identity", "undefined") != "undefined": break
            bench("eval", tab, "window.dispatchEvent(new Event('copies-ask')); 1")
            time.sleep(1.5); call = dataset(tab)
        try: identity = json.loads(call.get("identity") or "{}")
        except ValueError: identity = {}
        ok("identity.AccountStatus is Chrome's, getProfileUserInfo answers",
           identity.get("any") == "ANY" and identity.get("sync") == "SYNC"
           and identity.get("info") == {"email": "", "id": ""}, identity)
    finally:
        bench("quit")
        for _ in range(30):
            if not pids(): break
            time.sleep(0.2)
        for p in pids(): subprocess.run(["kill", p])
        time.sleep(0.5)
        wipe()
        shutil.rmtree(folder, ignore_errors=True)
    print(f"{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
