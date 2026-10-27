#!/usr/bin/env python3
"""Vimium C's options page and worker, made small, in a hidden probe: module
scripts that wait on a top-level await, getPlatformInfo applied to nothing,
and a port's listener reading what was kept on the port.

Build first (`./build.sh`), then `python3 Tests/extension_module_await.py`.
It runs a copy of build/Search.app under a bundle id of its own, in a world
of its own with split_view.py's harness, started hidden; the copy, its
WebKit folders and the world are removed afterwards.

Vimium C's options page lists its modules as five <script type="module">
tags. options_base.js awaits its translations at the top level before it
exports Option_, and options_defs.js, the next tag, imports Option_. Chrome
waits for the first to finish; WebKit runs the second tag's module while the
first is still waiting, so it reads Option_ before it exists ("Cannot access
'd' before initialization"), and the page stays blank (Sridhar, 1.0.5). The
extension written here does the same. What is checked:

- the module listed after one that awaits sees what that one exports;
- they still run in the order they are listed;
- a page with a single module, and a page with only classic scripts, are
  left as they were;
- runtime.getPlatformInfo.apply(0, [callback]) calls back, in a page and in
  the worker (WebKit hands out a fresh copy of it at each read, which can't
  be replaced, and a copy called with another `this` never answered: Vimium
  C's worker waited on it forever and turned every connection away, so its
  options stayed blank and its keys did nothing);
- a port's onMessage listener is handed the port onConnect gave, not
  another object for it (Vimium C reads its own state off it);
- the same for a website's content script's port, and for onDisconnect:
  Vimium C's worker keeps each tab's state on the port its content script
  opened ('port.s'), and every key a page sent it threw on the object WebKit
  handed its listener instead, so no key did anything (Sridhar, 1.0.7).
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

sv.use("hub-sp-modules")
BUNDLE = "com.officecommun.search.hubspmodules"
work = Path(tempfile.mkdtemp(prefix="search-modules-"))

FILES = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "Awaiting", "version": "1.0",
        "options_ui": {"page": "pages/options.html", "open_in_tab": True},
        "background": {"service_worker": "sw.js"},
        "content_scripts": [{"matches": ["http://127.0.0.1/*"], "js": ["content.js"], "run_at": "document_idle"}],
    }),
    # A website's content script: a port to the worker, a message on it, and
    # a second port it closes. What comes back is written on the page.
    "content.js": """
const note = (k, v) => { document.documentElement.dataset[k] = JSON.stringify(v); };
const port = chrome.runtime.connect({ name: 'tab' });
port.onMessage.addListener((m, from) => { note(m.kind, { ...m, sameHere: from === port }); });
port.postMessage('hello');
const bye = chrome.runtime.connect({ name: 'bye' });
bye.postMessage('first');
setTimeout(() => { bye.disconnect(); setTimeout(() => port.postMessage('after-bye'), 500); }, 500);
""",
    # Vimium C's worker: the platform asked for as getPlatformInfo.apply(0,
    # [callback]), and nothing answered on a port before it came back; what
    # it learns of a port is kept on the one onConnect handed it.
    "sw.js": """
let platform = null;
chrome.runtime.getPlatformInfo.apply(0, [(info) => { platform = info && info.os; }]);
let leftWith = null;
chrome.runtime.onConnect.addListener((port) => {
  port.mine = 'kept';
  if (port.name === 'bye') {
    port.onDisconnect.addListener((gone) => { leftWith = { same: gone === port, mine: gone && gone.mine }; });
    return;
  }
  port.onMessage.addListener((message, from) => {
    if (port.name === 'tab') {
      port.postMessage(message === 'after-bye'
        ? { kind: 'bye', ...leftWith }
        : { kind: 'tab', same: from === port, mine: from && from.mine });
      return;
    }
    port.postMessage({ platform, same: from === port, mine: from && from.mine });
  });
});
""",
    "pages/port.js": """
window.__p = null;
chrome.runtime.getPlatformInfo.apply(0, [(info) => { window.__gp = info && info.os; }]);
const port = chrome.runtime.connect({ name: 'ask' });
port.onMessage.addListener((m) => { window.__p = m; });
const ask = () => { if (!window.__p) { port.postMessage('hello'); setTimeout(ask, 500); } };
setTimeout(ask, 300);
""",
    "pages/port.html": '<!doctype html><html><head><script src="port.js"></script></head><body></body></html>',
    "pages/first.js": "window.__order = ['first'];",
    "pages/base.js": """
window.__order.push('base:start');
const words = await import('/i18n/en/options.js');
export class Option_ { static word = words.word; }
window.__order.push('base:end');
""",
    "i18n/en/options.js": "export const word = 'ready';",
    "pages/defs.js": """
import { Option_ } from './base.js';
window.__order.push('defs');
window.__r = Option_.word;
""",
    "pages/options.html": (
        '<!doctype html><html><head><meta charset="utf-8">'
        '<script defer src="first.js"></script>'
        '<script type="module" src="base.js" blocking="render"></script>'
        '<script type="module" src="defs.js" blocking="render"></script>'
        '</head><body><p>options</p></body></html>'),
    "pages/single.html": '<!doctype html><html><head><script src="first.js"></script><script type="module" src="defs.js"></script></head><body></body></html>',
    "pages/classic.html": '<!doctype html><html><head><script src="first.js"></script></head><body></body></html>',
}


def probe_copy():
    """build/Search.app (or the app the harness was pointed at) under a
    bundle id of its own, signed ad hoc."""
    app = work / "Search.app"
    shutil.copytree(sv.APP, app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def value(tid, js, within=6):
    end = time.time() + within
    got = None
    while time.time() < end:
        got = json.loads(sv.ev(tid, f"JSON.stringify({js})") or "null")
        if got:
            return got
        time.sleep(0.25)
    return got


def main():
    t = sv.T()
    folder = work / "ext"
    for name, body in FILES.items():
        (folder / name).parent.mkdir(parents=True, exist_ok=True)
        (folder / name).write_text(body)
    sv.APP = probe_copy()
    try:
        sv.setup()
        sv.launch()
        sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
        ext = None
        for _ in range(60):
            ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == "Awaiting" and x["loaded"]), None)
            if ext:
                break
            time.sleep(0.25)
        t.ok("the extension loads", ext is not None)
        if not ext:
            return t

        tid = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "pages/options.html"})["id"]
        got = value(tid, "window.__r || null")
        t.ok("the module after one that awaits sees what it exports", got == "ready", got)
        order = value(tid, "window.__order || null")
        t.ok("in the order they are listed, the awaited one finished first",
             order == ["first", "base:start", "base:end", "defs"], order)
        time.sleep(0.5)
        reported = next(x for x in sv.cmd({"do": "extensions"})["extensions"] if x["id"] == ext["id"]).get("reported", [])
        t.ok("no 'before initialization' error", not any("before initialization" in line for line in reported), reported)

        tid = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "pages/single.html"})["id"]
        t.ok("a page with one module runs it as before", value(tid, "window.__r || null") == "ready")
        tid = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "pages/classic.html"})["id"]
        t.ok("a page with classic scripts only runs them as before", value(tid, "window.__order || null") == ["first"])

        tid = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "pages/port.html"})["id"]
        got = value(tid, "window.__gp || null")
        t.ok("a page's getPlatformInfo applied to nothing calls back", got == "mac", got)
        got = value(tid, "window.__p || null", within=12)
        t.ok("the worker's getPlatformInfo applied to nothing calls back", got and got.get("platform") == "mac", got)
        t.ok("its port listener is handed the port onConnect gave it",
             got and got.get("same") is True and got.get("mine") == "kept", got)

        site = sv.page("content-port")
        got = value(site, "document.documentElement.dataset.tab || null")
        got = json.loads(got) if isinstance(got, str) else got
        t.ok("a content script's port: the worker's listener is handed the port onConnect gave",
             got and got.get("same") is True and got.get("mine") == "kept", got)
        t.ok("and the content script's own listener is handed its port", got and got.get("sameHere") is True, got)
        got = value(site, "document.documentElement.dataset.bye || null", within=8)
        got = json.loads(got) if isinstance(got, str) else got
        t.ok("onDisconnect is handed that port too", got and got.get("same") is True and got.get("mine") == "kept", got)

        installed = Path(sv.SUPPORT, "Extensions", ext["id"], "pages")
        html = (installed / "single.html").read_text() + (installed / "classic.html").read_text()
        t.ok("and neither page's scripts were touched", 'src="defs.js"' in html and 'src="first.js"' in html, html)
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
