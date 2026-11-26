#!/usr/bin/env python3
"""Ports from one of the extension's pages framed in a website, as ADI
Element Selector's panel opens one, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/extension_framed_ports.py`.
It runs a copy of build/Search.app under a bundle id of its own, hidden, in
a world of its own with split_view.py's harness; the copy, its WebKit
folders and the world are removed afterwards.

The extension has activeTab and scripting only: its toolbar button injects
the content script, which frames the extension's panel over the site. The
panel then opens ports three ways, each checked on its own:
  a) chrome.tabs.connect to its own tab's top frame, straight to the
     content script (the panel's own way);
  b) chrome.runtime.connect to the worker, which has to see the panel's tab
     as the port's sender;
  c) through that port, the worker's own chrome.tabs.connect to the content
     script it injected.
Each carries messages both ways, and a disconnect reaches the other end:
the frame's from its tabs.connect, the worker's from its own. A plain
runtime.connect port from the frame loses its disconnect in WebKit; the
frame's tabs.connect says it in a message instead.
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

sv.use("extension-framed-ports")
BUNDLE = "com.officecommun.search.framedports"
work = Path(tempfile.mkdtemp(prefix="search-framedports-"))

FILES = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "Framed Ports", "version": "1.0",
        "permissions": ["activeTab", "scripting", "storage"],
        "action": {"default_title": "Framed Ports"},
        "background": {"service_worker": "worker.js"},
        "web_accessible_resources": [{"resources": ["panel.html", "panel.js"], "matches": ["<all_urls>"]}],
    }),
    "worker.js": """
chrome.action.onClicked.addListener((tab) => {
  chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ['content.js'] });
});
chrome.runtime.onConnect.addListener((port) => {
  if (port.name !== 'b') return;
  const tab = port.sender && port.sender.tab;
  port.postMessage({ hop: 'b', tab: tab ? tab.id : null, frame: port.sender ? port.sender.frameId : null });
  if (!tab) return;
  // c: the worker's own port to the content script, piped to the panel.
  const inner = chrome.tabs.connect(tab.id, { frameId: 0, name: 'c' });
  inner.onMessage.addListener((m) => port.postMessage({ hop: 'c', message: m }));
  inner.onDisconnect.addListener(() => port.postMessage({ hop: 'c', gone: true }));
  port.onMessage.addListener((m) => {
    if (m === 'ping-c') inner.postMessage('ping');
    if (m === 'bye-c') inner.disconnect();
  });
});
""",
    "content.js": """
(() => {
  if (window.__framedPorts) return;
  window.__framedPorts = true;
  const say = (k, v) => document.documentElement.setAttribute('data-' + k, v);
  chrome.runtime.onConnect.addListener((port) => {
    say('heard-' + port.name, '1');
    port.postMessage({ type: 'shown', name: port.name });
    port.onMessage.addListener((m) => {
      if (m === 'ping') port.postMessage('pong');
    });
    port.onDisconnect.addListener(() => say('gone-' + port.name, '1'));
  });
  window.addEventListener('message', (e) => {
    if (e.data && e.data.framedPorts) for (const [k, v] of Object.entries(e.data.framedPorts)) say(k, v);
  });
  const frame = document.createElement('iframe');
  frame.src = chrome.runtime.getURL('panel.html');
  frame.style.cssText = 'position:fixed;top:20px;right:20px;width:300px;height:120px;border:0;z-index:99999';
  document.documentElement.append(frame);
  say('ready', '1');
})();
""",
    "panel.html": "<!doctype html><body>panel<script src=panel.js></script></body>",
    "panel.js": """
const tell = (k, v) => parent.postMessage({ framedPorts: { [k]: String(v) } }, '*');
(async () => {
  const tab = await chrome.tabs.getCurrent();
  tell('current', tab ? tab.id : 'none');
  // a: straight to the content script.
  const a = chrome.tabs.connect(tab.id, { frameId: 0, name: 'a' });
  a.onMessage.addListener((m) => {
    if (m && m.type === 'shown') { tell('a-shown', m.name); a.postMessage('ping'); }
    if (m === 'pong') { tell('a-pong', '1'); setTimeout(() => a.disconnect(), 200); }
  });
  a.onDisconnect.addListener(() => tell('a-closed', '1'));
  // b and c: to the worker, and through it.
  const b = chrome.runtime.connect({ name: 'b' });
  b.onMessage.addListener((m) => {
    if (m.hop === 'b') tell('b-tab', m.tab === tab.id ? 'own' : m.tab);
    if (m.hop === 'c' && m.message && m.message.type === 'shown') { tell('c-shown', m.message.name); b.postMessage('ping-c'); }
    if (m.hop === 'c' && m.message === 'pong') { tell('c-pong', '1'); b.postMessage('bye-c') }
  });
})().catch((e) => tell('error', e && e.message || e));
""",
}


def probe_copy():
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def attr(page, name):
    return sv.cmd({"do": "eval", "id": page, "js": f"document.documentElement.getAttribute('data-{name}') || ''"}).get("value")


def wait(page, name, within=8):
    until = time.time() + within
    while time.time() < until:
        value = attr(page, name)
        if value: return value
        time.sleep(0.2)
    return ""


def main():
    t = sv.T()
    folder = work / "ext"
    folder.mkdir()
    for name, body in FILES.items(): (folder / name).write_text(body)
    sv.APP = probe_copy()
    try:
        sv.setup()
        sv.launch()
        sv.cmd({"do": "ext-answer", "answer": "yes"})
        sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
        ext = None
        for _ in range(60):
            ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == "Framed Ports" and x["loaded"]), None)
            if ext: break
            time.sleep(0.25)
        t.ok("the extension loads", ext is not None)
        if not ext: return t
        page = sv.page("site")
        time.sleep(1)
        sv.cmd({"do": "ext-press", "id": ext["id"]})
        t.ok("the toolbar button injects the content script", wait(page, "ready") == "1", attr(page, "ready"))
        t.ok("the panel knows its tab", wait(page, "current") not in ("", "none"), attr(page, "current"))
        t.ok("no error in the panel", attr(page, "error") == "", attr(page, "error"))

        # a: the framed page's own tabs.connect.
        t.ok("a: tabs.connect from the frame reaches the content script", wait(page, "heard-a") == "1")
        t.ok("a: the content script's first message reaches the frame, under its name", wait(page, "a-shown") == "a", attr(page, "a-shown"))
        t.ok("a: and the frame's message reaches it back", wait(page, "a-pong") == "1")
        t.ok("a: the frame's disconnect reaches the content script", wait(page, "gone-a") == "1")
        t.ok("a: and its own end hears nothing of its own disconnect", attr(page, "a-closed") == "", attr(page, "a-closed"))

        # b: runtime.connect from the frame, with its tab as sender.
        t.ok("b: runtime.connect from the frame reaches the worker with the frame's tab", wait(page, "b-tab") == "own", attr(page, "b-tab"))
        # c: the worker's tabs.connect to the content script it injected.
        t.ok("c: tabs.connect from the worker reaches the injected content script", wait(page, "heard-c") == "1")
        t.ok("c: and its messages come back both ways", wait(page, "c-shown") == "c" and wait(page, "c-pong") == "1",
             (attr(page, "c-shown"), attr(page, "c-pong")))
        t.ok("c: the worker's disconnect reaches the content script", wait(page, "gone-c") == "1")
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
