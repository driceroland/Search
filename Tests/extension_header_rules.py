#!/usr/bin/env python3
"""An extension's own header rules reach its fetches the browser sends, in a
hidden probe.

Build first (`./build.sh`), then `python3 Tests/extension_header_rules.py`.
It runs a copy of build/Search.app under a bundle id of its own, in a world
of its own with split_view.py's harness, started hidden; the copy, its
WebKit folders and the world are removed afterwards.

Voice-over-Translation sets, with a declarativeNetRequest session rule, the
headers its translation service needs on its own request (Sec-Vtrans-*, a
User-Agent, no Origin). That request carries credentials, so the browser
sends it (ExtensionFetch), and WebKit's rules never applied there: the
service refused it, and VOT said it couldn't request the translation (idea
678). WebKit also refused the whole of a rule naming a header it doesn't
know (x-client-data). Served here: a pretend service that says what headers
reached it. What is checked:

- a rule's headers, Sec-* and User-Agent among them, reach the extension's
  credentialed fetch, and a rule removing Origin removes it;
- what the browser keeps for itself doesn't: a rule's Cookie or Host;
- a rule for one address doesn't reach another;
- a rule naming a header WebKit doesn't know is kept without that header,
  and that is in the extension's error list.
"""
import json
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("ext-header-rules")
BUNDLE = "com.officecommun.search.extheaderrules"
work = Path(tempfile.mkdtemp(prefix="search-extheaderrules-"))


class Service(BaseHTTPRequestHandler):
    """Says which headers reached it."""
    protocol_version = "HTTP/1.1"

    def answer(self):
        body = json.dumps({k.lower(): v for k, v in self.headers.items()}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.answer()

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n:
            self.rfile.read(n)
        self.answer()

    def log_message(self, *a):
        pass


def files(port):
    return {
        "manifest.json": json.dumps({
            "manifest_version": 3, "name": "HeaderRules", "version": "1.0",
            "background": {"service_worker": "sw.js"},
            "permissions": ["declarativeNetRequest"],
            "host_permissions": ["http://127.0.0.1/*", "http://localhost/*"],
        }),
        "sw.js": """
chrome.runtime.onMessage.addListener((m, sender, reply) => {
  (async () => {
    try {
      if (m.rules) { await chrome.declarativeNetRequest.updateSessionRules(m.rules); reply({ ok: true }); return; }
      if (m.list) { reply(await chrome.declarativeNetRequest.getSessionRules()); return; }
      const r = await fetch(m.url, { method: "POST", credentials: "include", body: "x" });
      reply(await r.json());
    } catch (e) { reply({ error: String(e) }); }
  })();
  return true;
});
""",
        "page.html": "<!doctype html><p>page</p>",
    }


def probe_copy():
    """build/Search.app under a bundle id of its own, signed ad hoc."""
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def run(tid, js, within=10):
    key = f"__r{int(time.time() * 1000)}"
    sv.ev(tid, f"window.{key}=null;Promise.resolve().then(()=>{js}).then(v=>window.{key}=JSON.stringify(v===undefined?null:v),"
               f"e=>window.{key}=JSON.stringify({{error:String(e)}}));1")
    end = time.time() + within
    while time.time() < end:
        value = sv.ev(tid, f"window.{key}")
        if value:
            return json.loads(value)
        time.sleep(0.25)
    return "timeout"


def ask(tid, message):
    return run(tid, f"chrome.runtime.sendMessage({json.dumps(message)})")


def main():
    t = sv.T()
    service = ThreadingHTTPServer(("127.0.0.1", 0), Service)
    threading.Thread(target=service.serve_forever, daemon=True).start()
    port = service.server_port
    folder = work / "ext"
    folder.mkdir()
    for name, body in files(port).items():
        (folder / name).write_text(body)
    sv.APP = probe_copy()
    try:
        sv.setup()
        sv.launch()
        sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
        ext = None
        for _ in range(60):
            ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == "HeaderRules" and x["loaded"]), None)
            if ext:
                break
            time.sleep(0.25)
        t.ok("the extension loads", ext is not None)
        if not ext:
            return t
        tid = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "page.html"})["id"]
        time.sleep(1.5)

        rule = {"id": 1, "priority": 1, "condition": {"urlFilter": f"|http://127.0.0.1:{port}/api/", "resourceTypes": ["xmlhttprequest"]},
                "action": {"type": "modifyHeaders", "requestHeaders": [
                    {"header": "Origin", "operation": "remove"},
                    {"header": "Sec-Vtrans-Token", "operation": "set", "value": "token-1"},
                    {"header": "User-Agent", "operation": "set", "value": "Mozilla/5.0 YaBrowser/25.4"},
                    {"header": "X-Plain", "operation": "set", "value": "plain"},
                    {"header": "Cookie", "operation": "set", "value": "stolen=1"},
                    {"header": "Host", "operation": "set", "value": "elsewhere.example"},
                ]}}
        unknown = {"id": 2, "priority": 1, "condition": {"urlFilter": "||youtube.example/", "resourceTypes": ["xmlhttprequest"]},
                   "action": {"type": "modifyHeaders", "requestHeaders": [
                       {"header": "x-client-data", "operation": "remove"},
                       {"header": "Origin", "operation": "remove"},
                   ]}}
        r = ask(tid, {"rules": {"removeRuleIds": [1, 2], "addRules": [rule, unknown]}})
        t.ok("the rules are taken", r == {"ok": True}, r)

        got = ask(tid, {"url": f"http://127.0.0.1:{port}/api/translate"})
        t.ok("a rule's Sec-* header reaches the extension's credentialed fetch", isinstance(got, dict) and got.get("sec-vtrans-token") == "token-1", got)
        t.ok("and its User-Agent and plain header", isinstance(got, dict) and "YaBrowser" in got.get("user-agent", "") and got.get("x-plain") == "plain", got)
        t.ok("a rule removing Origin removes it", isinstance(got, dict) and "origin" not in got, got)
        t.ok("a rule's Cookie and Host don't go", isinstance(got, dict) and "stolen" not in got.get("cookie", "")
             and got.get("host") == f"127.0.0.1:{port}", got)

        other = ask(tid, {"url": f"http://localhost:{port}/api/translate"})
        t.ok("a rule for one address doesn't reach another", isinstance(other, dict) and "sec-vtrans-token" not in other
             and "x-plain" not in other, other)

        listed = ask(tid, {"list": True})
        kept = next((x for x in listed if x.get("id") == 2), None) if isinstance(listed, list) else None
        names = [h.get("header", "").lower() for h in ((kept or {}).get("action") or {}).get("requestHeaders", [])]
        t.ok("a rule naming a header WebKit doesn't know is kept without it", kept is not None and names == ["origin"], listed)
        time.sleep(1)
        reported = next(x for x in sv.cmd({"do": "extensions"})["extensions"] if x["id"] == ext["id"]).get("reported", [])
        t.ok("and that is in its error list", any("x-client-data" in r and "left out of rule 2" in r for r in reported), reported)
    finally:
        sv.finish()
        service.shutdown()
        for kind in ("WebKit", "Caches", "HTTPStorages"):
            shutil.rmtree(Path.home() / "Library" / kind / BUNDLE, ignore_errors=True)
        shutil.rmtree(work, ignore_errors=True)
    return t


if __name__ == "__main__":
    t = main()
    t.done()
    sys.exit(1 if t.failed else 0)
