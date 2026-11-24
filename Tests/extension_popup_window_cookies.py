#!/usr/bin/env python3
"""An extension's popup fetches with the cookies of the window it was opened
from (idea 1045), in a hidden probe.

A fetch from an extension's page to a site it has been granted goes through
the browser (ExtensionFetch) with that site's cookies, from one store. A
worker doesn't say which window it is for, so with windows on different
stores (another profile, a signed-out space) nothing went — and neither did
anything from the popup, though it was opened from one window. Monarch's
"Connect Amazon" read Amazon's sign-in page and did nothing. Chrome sends
the popup's profile's cookies. The popup's shim now says it is the popup,
and the browser takes the store of the window the popup hangs from.

Two windows can't be opened in a hidden probe, so this checks what one
window shows: the popup's requests say they are the popup's, the worker's
don't, and the popup's cookies follow its window's space — a space of its
own, signed out, sends none.

Build first (`./build.sh debug`), then, one probe at a time,
`lockf -t 900 /private/tmp/claude-501/search-probe.lock python3 Tests/extension_popup_window_cookies.py`.
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

sv.use("popup-cookies")
BUNDLE = "com.officecommun.search.popupcookies"
work = Path(tempfile.mkdtemp(prefix="search-popup-cookies-"))
SITE = f"http://127.0.0.1:{sv.srv.server_port}"

FILES = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "Popup Cookies", "version": "1.0",
        "host_permissions": ["http://127.0.0.1/*"],
        "action": {"default_popup": "popup.html"},
        "background": {"service_worker": "worker.js"},
    }),
    "popup.html": "<!doctype html><title>popup</title><p>popup</p>",
    # The worker fetches when asked over a channel.
    "worker.js": """
const bc = new BroadcastChannel('ask');
bc.onmessage = async (e) => { if (e.data !== 'fetch') return;
  const r = await fetch('%s/long'); await r.text(); bc.postMessage('done ' + r.status); };
chrome.runtime.onMessage.addListener((m, s, reply) => { reply('awake'); });
""" % SITE,
}


def probe_copy():
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def popup(id, js, wait=20):
    """An async snippet's result, run in the open popup."""
    sv.cmd({"do": "ext-popup", "id": id, "js": "window.__r=undefined; (async()=>{try{window.__r=String(await (async()=>{" + js + "})())}catch(e){window.__r='ERR '+e}})(); 1"})
    end = time.time() + wait
    while time.time() < end:
        r = sv.cmd({"do": "ext-popup", "id": id, "js": "window.__r===undefined?null:window.__r"})
        if r.get("value") is not None or r.get("error"): return r.get("value", r.get("error"))
        time.sleep(0.3)
    return "timeout"


def fetched(id, js):
    """What went through the browser for the snippet: popup flag and cookie names."""
    sv.cmd({"do": "ext-fetches", "clear": True})
    said = popup(id, js)
    trace = [e for e in sv.cmd({"do": "ext-fetches"})["trace"] if "/long" in (e.get("native") or e.get("pass") or "")]
    return said, [(e.get("popup"), "probe" in e.get("cookies", []), "pass" in e) for e in trace]


def main():
    t = sv.T()
    folder = work / "ext"
    folder.mkdir()
    for name, body in FILES.items(): (folder / name).write_text(body)
    sv.APP = probe_copy()
    try:
        sv.setup(spaces=True)
        sv.launch()
        sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
        id = None
        for _ in range(60):
            ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == "Popup Cookies" and x["loaded"]), None)
            if ext: id = ext["id"]; break
            time.sleep(0.25)
        t.ok("the extension loads", id is not None)
        if not id: return t
        page = sv.sp("open", url=f"{SITE}/long")["resultID"]
        time.sleep(1.5)
        sv.ev(page, "document.cookie='probe=1; path=/; SameSite=Lax; max-age=600'; 1")
        sv.cmd({"do": "ext-press", "id": id})
        time.sleep(2)
        own = f"const r=await fetch('{SITE}/long'); await r.text(); return r.status"
        said, went = fetched(id, own)
        t.ok("the popup's fetch says it is the popup's and carries its window's cookie", said == "200" and went[:1] == [(True, True, False)], (said, went))
        said, went = fetched(id, """await chrome.runtime.sendMessage('wake');
          const bc=new BroadcastChannel('ask'); return await new Promise(res=>{bc.onmessage=e=>res(e.data); bc.postMessage('fetch'); setTimeout(()=>bc.postMessage('fetch'),1500); setTimeout(()=>res('no answer'),10000)})""")
        t.ok("the worker's fetch doesn't say it is the popup's", said == "done 200" and went[:1] and went[0][0] is False, (said, went))
        sv.cmd({"do": "ext-popup", "id": id, "js": "window.close()"})
        time.sleep(0.5)
        sv.cmd({"do": "space", "action": "new", "name": "Apart", "fresh": True})
        time.sleep(2)
        t.ok("a signed-out space is the window's now", sv.cmd({"do": "space"}).get("current") == "Apart")
        sv.cmd({"do": "ext-press", "id": id})
        time.sleep(2)
        said, went = fetched(id, own)
        t.ok("opened there, the popup's fetch goes with that space's cookies: none", said == "200" and went[:1] == [(True, False, False)], (said, went))
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
