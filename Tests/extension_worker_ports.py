#!/usr/bin/env python3
"""An extension's page and its worker talk over a MessagePort, both ways — in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/extension_worker_ports.py`.
Same harness as extension_install_event.py: a copy of build/Search.app under
a bundle id of its own, in a world of its own, started hidden; the copy, its
WebKit folders and the world are removed afterwards.

Zotero Connector's offscreen page hands its worker a MessagePort, as Chrome
lets it, through (await navigator.serviceWorker.ready).active, and tells the
worker it is ready on that port. WebKit's `active` there never reaches the
extension's worker, and Search's stand-in passed a port's messages one way
only, worker to page. The worker never heard, Zotero never finished
starting, and its button did nothing (#1236). A local extension whose worker
answers on any port it is handed:

- a port handed over through navigator.serviceWorker.controller carries the
  worker's message to the page, and the page's back to the worker;
- so does one handed over through ready's `active`, and ready still
  brings WebKit's own registration, with its methods;
- a port the worker hands "that page" reaches both pages open at its
  address, as before, but one page's messages on it go to the worker, never
  to the other page.
"""
import json
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("sec-worker-ports")
BUNDLE = "com.officecommun.search.workerports"
work = Path(tempfile.mkdtemp(prefix="search-worker-ports-"))

FILES = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "PortsBothWays", "version": "1.0",
        "description": "A worker that answers on a port a page hands it.",
        "background": {"service_worker": "sw.js"},
    }),
    # As Zotero's OffscreenManager does: listen on the port, answer on it.
    "sw.js": """
self.onmessage = (e) => {
  // The other way round: the worker hands the page that asked a port.
  if (e.data === 'give' && e.source) {
    const channel = new MessageChannel();
    channel.port1.onmessage = (m) => channel.port1.postMessage('echo:' + m.data);
    e.source.postMessage('take', [channel.port2]);
    return;
  }
  if (e.data !== 'port' || !e.ports[0]) return;
  const port = e.ports[0];
  port.onmessage = (m) => port.postMessage('echo:' + m.data);
  port.postMessage('hello');
};
""",
    "page.html": "<!doctype html><title>page</title>",
}

# A port handed to `target`; what came back on it before and after the page
# spoke on its own end.
TALK = """
(async () => {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const talk = async (target) => {
    if (!target) return 'nothing to post to';
    const got = [];
    const channel = new MessageChannel();
    channel.port1.onmessage = (e) => got.push(e.data);
    target.postMessage('port', [channel.port2]);
    for (let i = 0; i < 50 && got.length < 1; i++) await sleep(100);
    channel.port1.postMessage('ping');
    for (let i = 0; i < 50 && got.length < 2; i++) await sleep(100);
    return got;
  };
  const registration = await navigator.serviceWorker.ready;
  return {
    registration: Object.prototype.toString.call(registration),
    showNotification: typeof registration.showNotification,
    same: navigator.serviceWorker.ready === navigator.serviceWorker.ready,
    controller: await talk(navigator.serviceWorker.controller),
    ready: await talk(registration.active),
  };
})()
"""


def probe_copy():
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def wait_for(name, within=30):
    end = time.time() + within
    while time.time() < end:
        ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == name and x["loaded"]), None)
        if ext:
            return ext
        time.sleep(0.25)
    return None


def read(page, js, within=30):
    """A promise's value in one of the extension's pages, as JSON."""
    end = time.time() + within
    while time.time() < end:
        try:
            if sv.ev(page, "typeof navigator.serviceWorker !== 'undefined' && document.readyState === 'complete'"):
                break
        except RuntimeError:
            pass
        time.sleep(0.25)
    sv.ev(page, "window.__o = null; Promise.resolve(" + js + ").then((v) => window.__o = JSON.stringify(v ?? null),"
                " (e) => window.__o = JSON.stringify({ error: String(e && e.message || e) })); 1")
    while time.time() < end:
        got = sv.ev(page, "window.__o")
        if isinstance(got, str):
            return json.loads(got)
        time.sleep(0.25)
    return None


# A page that keeps whatever comes on a port the worker hands it.
TAKE = """
window.heard = [];
navigator.serviceWorker.addEventListener('message', (e) => {
  if (e.data !== 'take' || !e.ports[0]) return;
  window.taken = e.ports[0];
  window.taken.onmessage = (m) => window.heard.push(m.data);
});
1
"""


def main():
    t = sv.T()
    sv.APP = probe_copy()
    try:
        sv.setup()
        sv.launch()
        folder = work / "ports-both-ways"
        folder.mkdir()
        for name, body in FILES.items():
            (folder / name).write_text(body)
        sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
        ext = wait_for("PortsBothWays")
        t.ok("the extension loads", ext is not None)
        if not ext:
            return t
        page = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "page.html"})["id"]
        got = read(page, TALK) or {}
        print(f"       {got}")
        both = ["hello", "echo:ping"]
        t.ok("through controller: the worker's message reaches the page", (got.get("controller") or [])[:1] == ["hello"], got)
        t.ok("… and the page's reaches the worker", got.get("controller") == both, got)
        t.ok("through ready's active: the worker's message reaches the page", (got.get("ready") or [])[:1] == ["hello"], got)
        t.ok("… and the page's reaches the worker", got.get("ready") == both, got)
        t.ok("ready brings WebKit's own registration, with its methods",
             got.get("registration") == "[object ServiceWorkerRegistration]" and got.get("showNotification") == "function", got)
        t.ok("… and is the same promise each time it is read", got.get("same") is True, got)
        sv.cmd({"do": "close", "id": page})

        # Two pages at one address; the first asks the worker for a port.
        first, second = (sv.cmd({"do": "ext-page", "id": ext["id"], "path": "page.html"})["id"] for _ in range(2))
        for page in (first, second):
            read(page, "1")
            sv.ev(page, TAKE)
        sv.ev(first, "navigator.serviceWorker.controller.postMessage('give'); 1")
        end = time.time() + 10
        while time.time() < end and not sv.ev(first, "!!window.taken"):
            time.sleep(0.25)
        sv.ev(first, "window.taken && window.taken.postMessage('hi'); 1")
        time.sleep(2)
        heard = {name: json.loads(sv.ev(page, "JSON.stringify(window.heard)") or "[]") for name, page in (("first", first), ("second", second))}
        print(f"       {heard}")
        t.ok("a port the worker hands a page: the page's message reaches the worker", heard["first"] == ["echo:hi"], heard)
        t.ok("… and not the other page at the same address", "hi" not in heard["second"], heard)
        for page in (first, second):
            sv.cmd({"do": "close", "id": page})
    finally:
        sv.finish()
        for kind in ("WebKit", "Caches", "HTTPStorages"):
            shutil.rmtree(Path.home() / "Library" / kind / BUNDLE, ignore_errors=True)
        shutil.rmtree(work, ignore_errors=True)
    return t


if __name__ == "__main__":
    t = main()
    t.done()
    sys.exit(1 if t.failed else 0)
