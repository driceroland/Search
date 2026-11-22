#!/usr/bin/env python3
"""An extension's sandbox pages may eval, apart from its own pages, as in Chrome — in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/extension_sandbox_pages.py`.
Same harness as extension_install_event.py: a copy of build/Search.app under
a bundle id of its own, in a world of its own, started hidden; the copy, its
WebKit folders and the world are removed afterwards.

Chrome serves the pages a manifest lists under "sandbox" apart from the
extension's origin, without its APIs, and lets them eval: Manifest V3's one
way to run code given as text. Zotero Connector runs its translators so, in a
sandbox page framed by its offscreen document, under a policy of its own
(#1236). WebKit ignores the key. Search serves those pages itself
(ExtensionSandbox). Local extensions:

- sandbox pages framed in the page's HTML, by a script, and one with its own
  policy asking for 'unsafe-eval', as Zotero's: each evals and runs inline
  script, with an opaque origin and nothing of the extension's, never first
  loaded as an ordinary extension page;
- they can't read a site the extension may (its own page can);
- the extension's own page still refuses eval, new Function, inline script;
- the same from an offscreen document;
- a frame with a sandbox attribute of its own is left alone, and one a page's
  own policy won't let it frame there loads as before, without eval;
- one whose own pages' policy asks for 'unsafe-eval', which Chrome refuses in
  Manifest V3: its pages still refuse eval, and WebKit's mode stays, so only
  sandbox pages without a script-src of their own eval;
- a Manifest V2 background page's frame on its sandbox page loads as before.
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

sv.use("sec-sandbox-pages")
BUNDLE = "com.officecommun.search.sandboxpages"
work = Path(tempfile.mkdtemp(prefix="search-sandbox-pages-"))
PRIVATE = sv.BASE + "/private"

PAGE_JS = """
window.got = [];
window.addEventListener('message', (e) => window.got.push(Object.assign({ sender: e.origin }, e.data)));
window.own = {};
try { window.own.eval = eval('1 + 1'); } catch (e) { window.own.eval = 'refused'; }
try { window.own.fn = new Function('return 1')(); } catch (e) { window.own.fn = 'refused'; }
fetch(%r, { credentials: 'include' }).then((r) => r.text()).then(() => { window.own.fetch = 'read'; }, () => { window.own.fetch = 'refused'; });
document.addEventListener('DOMContentLoaded', () => {
  const inline = document.createElement('script');
  inline.textContent = "window.own.inline = 'ran'";
  document.head.appendChild(inline);
  const frame = document.createElement('iframe');
  frame.src = chrome.runtime.getURL('sb.html?script');
  document.body.appendChild(frame);
});
""" % PRIVATE
SANDBOX_JS = """
const r = { which: location.search.slice(1), origin: String(self.origin), inline: !!self.inlineRan,
            apis: typeof chrome !== 'undefined' && !!(chrome.runtime && chrome.runtime.id) };
try { r.eval = eval('40 + 2'); } catch (e) { r.eval = 'refused'; }
try { r.fn = new Function('return 7')(); } catch (e) { r.fn = 'refused'; }
try { localStorage.length; r.storage = 'yes'; } catch (e) { r.storage = 'no'; }
fetch(%r, { credentials: 'include' }).then((x) => x.text()).then(() => 'read', () => 'refused')
  .then((how) => { r.fetch = how; parent.postMessage(r, '*'); });
""" % PRIVATE
SANDBOX = '<!doctype html><title>sandbox</title><script>self.inlineRan = true</script><script src="sb.js"></script>'
# As Zotero's: a policy of its own, eval asked for.
OWN_POLICY = ('<!doctype html><meta http-equiv="Content-Security-Policy" content="default-src \'none\'; script-src \'self\' \'unsafe-eval\'">'
              '<title>own policy</title><script src="sb.js"></script>')


def package(name, policy=None):
    manifest = {
        "manifest_version": 3, "name": name, "version": "1.0",
        "description": "Frames its sandbox pages and asks them to eval.",
        "host_permissions": ["http://127.0.0.1/*"],
        "background": {"service_worker": "sw.js"},
        "sandbox": {"pages": ["sb.html", "own.html"]},
    }
    if policy:
        manifest["content_security_policy"] = {"extension_pages": policy}
    return {
        "manifest.json": json.dumps(manifest),
        "sw.js": "// nothing to do\n",
        # Written in the page's HTML, as Zotero's offscreen page frames its sandbox.
        "page.html": '<!doctype html><title>page</title><script src="page.js"></script>'
                     '<iframe src="sb.html?html"></iframe><iframe src="own.html?own"></iframe>'
                     '<iframe sandbox="allow-scripts" src="sb.html?attr"></iframe>',
        # A page whose own policy lets it frame only its own origin.
        "strict.html": '<!doctype html><meta http-equiv="Content-Security-Policy" content="frame-src \'self\'">'
                       '<title>strict</title><script src="page.js"></script><iframe src="sb.html?strict"></iframe>',
        "page.js": PAGE_JS,
        "sb.html": SANDBOX,
        "own.html": OWN_POLICY,
        "sb.js": SANDBOX_JS,
    }


# Zotero's path: the worker makes an offscreen document, which frames the
# sandbox page and passes on what it says.
OFFSCREEN = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "SandboxOffscreen", "version": "1.0",
        "description": "Its offscreen document frames its sandbox page.",
        "permissions": ["offscreen", "storage"],
        "background": {"service_worker": "sw.js"},
        "sandbox": {"pages": ["own.html"]},
    }),
    "sw.js": """
chrome.runtime.onMessage.addListener((m) => { if (m && m.said) chrome.storage.local.set({ said: m.said }); });
chrome.offscreen.createDocument({ url: 'offscreen.html', reasons: ['DOM_PARSER'], justification: 'test' });
""",
    "offscreen.html": '<!doctype html><title>offscreen</title><script src="off.js"></script><iframe src="own.html?offscreen"></iframe>',
    "off.js": "window.addEventListener('message', (e) => chrome.runtime.sendMessage({ said: Object.assign({ sender: e.origin }, e.data) }));",
    "page.html": "<!doctype html><title>page</title>",
    "own.html": OWN_POLICY,
    "sb.js": SANDBOX_JS,
}

# Manifest V2, its background a page that frames its sandbox page and keeps
# what the frame says.
BACKGROUND = {
    "manifest.json": json.dumps({
        "manifest_version": 2, "name": "SandboxInBackground", "version": "1.0",
        "description": "Its background page frames its sandbox page.",
        "permissions": ["storage"],
        "background": {"page": "background.html"},
        "sandbox": {"pages": ["sb.html"]},
    }),
    "background.html": '<!doctype html><title>bg</title><script src="bg.js"></script><iframe src="sb.html?background"></iframe>',
    "bg.js": "window.addEventListener('message', (e) => chrome.storage.local.set({ said: Object.assign({ sender: e.origin }, e.data) }));",
    "page.html": "<!doctype html><title>page</title>",
    "sb.html": SANDBOX,
    "sb.js": SANDBOX_JS,
}


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


def install(name, policy=None, files=None):
    folder = work / name
    folder.mkdir()
    for file, body in (files or package(name, policy)).items():
        (folder / file).write_text(body)
    sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
    return wait_for(name)


def frames(ext, want=4, within=15, path="page.html"):
    """What the page's sandbox frames said, every message, and the page's own results."""
    page = sv.cmd({"do": "ext-page", "id": ext["id"], "path": path})["id"]
    end = time.time() + within
    while time.time() < end:
        try:
            if len(json.loads(sv.ev(page, "JSON.stringify(window.got || [])") or "[]")) >= want:
                break
        except (RuntimeError, ValueError):
            pass
        time.sleep(0.25)
    time.sleep(1)  # anything said after them, too
    got = json.loads(sv.ev(page, "JSON.stringify(window.got || [])") or "[]")
    own = json.loads(sv.ev(page, "JSON.stringify(window.own || {})") or "{}")
    sv.cmd({"do": "close", "id": page})
    return {g.get("which"): g for g in got}, own, got


def kept(ext, within=20):
    """What a background or offscreen page's sandbox frame said, as the worker or page kept it."""
    page = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "page.html"})["id"]
    end = time.time() + within
    said = None
    while time.time() < end and not said:
        try:
            sv.ev(page, "chrome.storage.local.get('said').then((r) => window.__said = JSON.stringify(r.said || null)); 1")
            time.sleep(0.5)
            said = json.loads(sv.ev(page, "window.__said || 'null'"))
        except (RuntimeError, ValueError):
            time.sleep(0.5)
    sv.cmd({"do": "close", "id": page})
    return said


def main():
    t = sv.T()
    sv.APP = probe_copy()
    try:
        sv.setup()
        sv.launch()
        ext = install("SandboxPages")
        t.ok("an extension with sandbox pages loads", ext is not None)
        if not ext:
            return t
        got, own, said = frames(ext)
        print(f"       frames: {got}\n       its own page: {own}")
        t.ok("each frame speaks once, from an opaque origin: never first as an ordinary extension page",
             len(said) == 4 and all(g.get("sender") == "null" for g in said), said)
        t.ok("a frame with a sandbox attribute of its own is left alone, and loads",
             got.get("attr", {}).get("eval") == "refused", got.get("attr"))
        for which, how in (("html", "framed in its page's HTML"), ("script", "framed by a script"), ("own", "with a policy of its own, as Zotero's")):
            f = got.get(which, {})
            t.ok(f"{how}: the sandbox page evals", f.get("eval") == 42 and f.get("fn") == 7, f)
            t.ok("… with an opaque origin, no extension APIs and no storage",
                 f.get("origin") == "null" and f.get("apis") is False and f.get("storage") == "no", f)
            t.ok("… and can't read a site the extension may", f.get("fetch") == "refused", f)
        t.ok("inline script runs in a sandbox page", got.get("html", {}).get("inline") is True, got.get("html"))
        t.ok("its own page still refuses eval and new Function", own.get("eval") == "refused" and own.get("fn") == "refused", own)
        t.ok("… and an inline script", "inline" not in own, own)
        t.ok("… and may read that site, as the extension's pages may", own.get("fetch") == "read", own)
        got, _, said = frames(ext, want=2, path="strict.html")
        print(f"       a page whose policy frames only its own origin: {got}")
        origin = f"chrome-extension://{ext['id']}"
        t.ok("a page whose own policy won't frame them there: its frames load as before, without eval",
             {g.get("which") for g in said} == {"strict", "script"} and all(g.get("sender") == origin and g.get("eval") == "refused" for g in said), said)

        off = install("SandboxOffscreen", files=OFFSCREEN)
        t.ok("an extension whose offscreen document frames its sandbox page loads", off is not None)
        if off:
            said = kept(off)
            print(f"       offscreen frame: {said}")
            t.ok("… and that frame evals, apart", bool(said) and said.get("eval") == 42 and said.get("sender") == "null", said)

        more = install("SandboxAskingMore", "script-src 'self' 'unsafe-eval'; object-src 'self'")
        t.ok("an extension whose own policy asks for 'unsafe-eval' loads", more is not None)
        if more:
            got, own, _ = frames(more)
            print(f"       frames: {got}\n       its own page: {own}")
            t.ok("its own page still refuses eval", own.get("eval") == "refused", own)
            t.ok("WebKit's mode stays: a sandbox page with a script-src of its own can't eval",
                 got.get("own", {}).get("eval") == "refused" and got.get("own", {}).get("sender") == "null", got.get("own"))
            t.ok("… one without still can", got.get("html", {}).get("eval") == 42, got.get("html"))

        mv2 = install("SandboxInBackground", files=BACKGROUND)
        t.ok("a Manifest V2 extension whose background page frames its sandbox page loads", mv2 is not None)
        if mv2:
            said = kept(mv2)
            print(f"       background frame: {said}")
            t.ok("… and that frame loads, as before", bool(said) and said.get("which") == "background", said)
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
