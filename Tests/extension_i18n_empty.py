#!/usr/bin/env python3
"""chrome.i18n.getMessage("") is "" as in Chrome, so uBlock Origin's popup
runs and its dashboard button opens the dashboard (idea 975) — in a hidden
probe, without the network.

Build first (`./build.sh`), then `python3 Tests/extension_i18n_empty.py`. A
copy of build/Search.app under a bundle id of its own, hidden, in a world of
its own; the copy, its WebKit folders and the world are removed afterwards.

uBlock Origin's i18n module, as it loads, asks getMessage for every element's
aria-label, and its popup has bare ones (`aria-label` with no value): WebKit
threw on the empty name where Chrome answers "", the module failed, and so
did every module importing it — the popup's whole script. Its buttons, the
dashboard's among them, did nothing. A local extension of the same shape:
a popup page whose module imports one that reads the bare aria-labels, then
binds a link that asks the worker to open the options page.
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

sv.use("extension-i18n-empty")
BUNDLE = "com.officecommun.search.i18nempty"
work = Path(tempfile.mkdtemp(prefix="search-i18n-empty-"))

FILES = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "EmptyName", "version": "1.0", "default_locale": "en",
        "permissions": ["tabs"],
        "background": {"service_worker": "sw.js"},
        "action": {"default_popup": "popup.html"},
        "options_ui": {"page": "dashboard.html", "open_in_tab": True},
    }),
    "_locales/en/messages.json": json.dumps({"hello": {"message": "Hello"}}),
    "sw.js": """
chrome.runtime.onMessage.addListener((m) => {
  if (m && m.what === 'gotoURL') chrome.tabs.create({ url: chrome.runtime.getURL(m.url) });
});
""",
    "i18n.js": """
const i18n$ = (...args) => chrome.i18n.getMessage(...args);
for (const elem of document.querySelectorAll('[aria-label]')) {
  const text = i18n$(elem.getAttribute('aria-label'));
  if (text) elem.setAttribute('aria-label', text);
}
export { i18n$ };
""",
    "popup.js": """
import { i18n$ } from './i18n.js';
document.querySelector('a[href]').addEventListener('click', (ev) => {
  ev.preventDefault();
  chrome.runtime.sendMessage({ what: 'gotoURL', url: ev.target.getAttribute('href') });
});
document.body.dataset.ready = i18n$('hello');
""",
    "popup.html": "<!doctype html><title>Popup</title><body><span role=button aria-label tabindex=0>x</span>"
                  "<a href='dashboard.html'>Dashboard</a><script type=module src=popup.js></script></body>",
    "dashboard.html": "<!doctype html><title>Dashboard</title><p>dashboard</p>",
}


def probe_copy():
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def main():
    t = sv.T()
    sv.APP = probe_copy()
    try:
        sv.setup()
        sv.launch()
        folder = work / "ext"
        for name, body in FILES.items():
            (folder / name).parent.mkdir(parents=True, exist_ok=True)
            (folder / name).write_text(body)
        sv.cmd({"do": "ext-answer", "answer": "yes"})
        sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
        ext = None
        for _ in range(40):
            ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == "EmptyName" and x["loaded"]), None)
            if ext: break
            time.sleep(0.5)
        t.ok("the extension loads", ext is not None)
        if not ext: return t
        page = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "popup.html"})["id"]
        time.sleep(3)
        got = json.loads(sv.ev(page, "JSON.stringify([(() => { try { return chrome.i18n.getMessage('') } catch (e) { return 'threw' } })(),"
                                     " (() => { try { return browser.i18n.getMessage('') } catch (e) { return 'threw' } })(),"
                                     " chrome.i18n.getMessage('hello'), document.body.dataset.ready || null])"))
        t.ok("chrome.i18n.getMessage('') is '', as in Chrome", got[0] == "", got)
        t.ok("…and browser.i18n's", got[1] == "", got)
        t.ok("a named message still answers", got[2] == "Hello", got)
        t.ok("the popup's module, importing one that reads bare aria-labels, runs to its end", got[3] == "Hello", got)
        before = {x["id"] for x in sv.cmd({"do": "tabs"})["tabs"]}
        sv.ev(page, "document.querySelector('a[href]').click(); 1")
        opened = None
        for _ in range(30):
            time.sleep(0.3)
            opened = next((x for x in sv.cmd({"do": "tabs"})["tabs"] if x["id"] not in before and x["url"].endswith("/dashboard.html")), None)
            if opened: break
        t.ok("its dashboard link opens the dashboard, through the worker", opened is not None,
             [x["url"] for x in sv.cmd({"do": "tabs"})["tabs"]])
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
