#!/usr/bin/env python3
"""A frame's own request meets initiatorDomains as in Chrome (idea 712) — in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/extension_initiator_frames.py`
(needs the network: example.com and www.example.com). Same harness as
extension_ubol.py: a copy of build/Search.app under a bundle id of its own,
in a world of its own, started hidden; the copy, its WebKit folders and the
world are removed afterwards.

WebKit checks a declarativeNetRequest rule's initiatorDomains and
excludedInitiatorDomains against the frame a request is for. For a frame's
own request (sub_frame) that is the frame being loaded, still about:blank;
Chrome checks the page that holds it. Privacy Badger's "block soundcloud.com
unless soundcloud.com asked" so blocked SoundCloud's own sign-in frame on
soundcloud.com, and "Sign in" did nothing. The shim gives the frame part of
such a rule a rule of its own, checked against the page (domains /
excludedDomains).

On https://www.example.com, with a local extension's dynamic rules for
requests to example.com:

- excluded when example.com asked (Privacy Badger's shape): a frame and a
  fetch both load;
- only when example.com asked: a frame and a fetch are both blocked (WebKit
  let the frame through);
- the same as a session rule, frames only: the frame is blocked;
- the extension reads back only its own rules, as it wrote them in number;
- a rule taken away takes its frame part with it.

With SEARCH_BADGER=1, the real Privacy Badger from the Chrome Web Store too:
on soundcloud.com, the sign-in frame loads and "Sign in" shows it
(is_visible=true in its address). No account; nothing is typed.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("initiator-frames")
BUNDLE = "com.officecommun.search.initiatorframes"
BADGER = "pkehgijcmpdhfbdbbnkijodmdjhbjlgp"
work = Path(tempfile.mkdtemp(prefix="search-initiator-"))

FILES = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "InitiatorLike", "version": "1.0", "description": "test",
        "permissions": ["declarativeNetRequest", "storage"],
        "host_permissions": ["<all_urls>"],
        "background": {"service_worker": "sw.js"},
    }),
    "sw.js": """
const R = (id, c) => ({ id, priority: 1, action: { type: 'block' },
  condition: { requestDomains: ['example.com'], urlFilter: 'v' + id + '=', ...c } });
const dnr = chrome.declarativeNetRequest;
dnr.getDynamicRules().then((old) => dnr.updateDynamicRules({ removeRuleIds: old.map((r) => r.id), addRules: [
  R(1, { excludedInitiatorDomains: ['example.com', 'sndcdn.com'] }),
  R(2, { initiatorDomains: ['example.com'] }),
  R(3, { excludedInitiatorDomains: ['example.com'], resourceTypes: ['sub_frame', 'xmlhttprequest'] }),
]})).then(() => dnr.updateSessionRules({ addRules: [R(4, { initiatorDomains: ['example.com'], resourceTypes: ['sub_frame'] })] }))
  .then(() => chrome.storage.session.set({ ready: true }), (e) => chrome.storage.session.set({ ready: String(e && e.message || e) }));
""",
    "page.html": "<!doctype html><title>page</title>",
}

# Each of rules 1-4 marks its own requests: a frame and a fetch.
PROBE = """window.__l = {}; for (const v of [1, 2, 3, 4, 5]) {
  const f = document.createElement('iframe'); f.onload = () => __l['f' + v] = 1;
  f.src = 'https://example.com/?v' + v + '=f'; document.body.appendChild(f);
  fetch('https://example.com/?v' + v + '=x', { mode: 'no-cors' }).then(() => __l['x' + v] = 1, () => __l['x' + v] = 0);
} 1"""


def probe_copy():
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def wait_for(match, within=60):
    end = time.time() + within
    while time.time() < end:
        ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if match(x) and x["loaded"]), None)
        if ext:
            return ext
        time.sleep(0.5)
    return None


def ask(tab, js, within=6):
    """A promise's answer in an extension page, as JSON."""
    sv.ev(tab, f"window.__a = undefined; Promise.resolve({js}).then((r) => window.__a = JSON.stringify(r), (e) => window.__a = JSON.stringify('ERR ' + e)); 1")
    end = time.time() + within
    while time.time() < end:
        got = sv.ev(tab, "window.__a === undefined ? null : window.__a")
        if isinstance(got, str):
            return json.loads(got)
        time.sleep(0.25)
    return None


def loads():
    tab = sv.cmd({"do": "open", "url": "https://www.example.com/"})["id"]
    for _ in range(40):
        time.sleep(0.25)
        if sv.ev(tab, "document.readyState") == "complete":
            break
    sv.ev(tab, PROBE)
    time.sleep(6)
    got = json.loads(sv.ev(tab, "JSON.stringify(__l)"))
    sv.cmd({"do": "close", "id": tab})
    return got


def local_part(t):
    folder = work / "initiator"
    folder.mkdir()
    for name, body in FILES.items():
        (folder / name).write_text(body)
    sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
    ext = wait_for(lambda x: x["name"] == "InitiatorLike", 20)
    t.ok("the extension with initiator rules loads", ext is not None)
    if not ext:
        return
    page = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "page.html"})["id"]
    ready = None
    for _ in range(40):
        try:
            ready = ask(page, "chrome.storage.session.get('ready').then((r) => r.ready ?? null)")
        except RuntimeError:
            ready = None  # the page not up yet
        if ready is not None:
            break
        time.sleep(0.25)
    t.ok("its rules go in", ready is True, ready)

    got = loads()
    print(f"       loads: {got}")
    t.ok("excluded when the page's site asked: its frame loads, as in Chrome", got.get("f1") == 1, got)
    t.ok("… and so does its fetch", got.get("x1") == 1, got)
    t.ok("only when the page's site asked: its frame is blocked, as in Chrome", "f2" not in got, got)
    t.ok("… and so is its fetch", got.get("x2") == 0, got)
    t.ok("frames and fetches named together, excluded: the frame loads", got.get("f3") == 1, got)
    t.ok("a session rule for frames only, when the page's site asked: blocked", "f4" not in got, got)
    t.ok("a request no rule names loads", got.get("f5") == 1 and got.get("x5") == 1, got)

    dynamic = ask(page, "chrome.declarativeNetRequest.getDynamicRules()")
    session = ask(page, "chrome.declarativeNetRequest.getSessionRules()")
    t.ok("the extension reads back only its own rules", sorted(r["id"] for r in dynamic or []) == [1, 2, 3]
         and [r["id"] for r in session or []] == [4], (dynamic, session))
    # A rule for frames alone reads back with its sites as domains, Chrome's
    # older name for initiatorDomains: WebKit checks those against the page.
    t.ok("… with the sites it gave them", all(r["condition"].get("excludedInitiatorDomains") or r["condition"].get("initiatorDomains")
                                               or r["condition"].get("domains")
                                               for r in (dynamic or []) + (session or [])), (dynamic, session))

    ask(page, "chrome.declarativeNetRequest.updateDynamicRules({ removeRuleIds: [2] }).then(() => chrome.declarativeNetRequest.updateSessionRules({ removeRuleIds: [4] }))")
    time.sleep(1)
    got = loads()
    t.ok("a rule taken away takes its frame part with it", got.get("f2") == 1 and got.get("f4") == 1, got)
    sv.cmd({"do": "close", "id": page})
    sv.cmd({"do": "ext-remove", "id": ext["id"]})
    time.sleep(1)


def real_badger(t):
    sv.cmd({"do": "ext-answer", "answer": "yes"})
    sv.cmd({"do": "ext-add", "id": BADGER, "yes": True})
    ext = wait_for(lambda x: x["id"] == BADGER, 90)
    t.ok("Privacy Badger installs from the Chrome Web Store and loads", ext is not None)
    if not ext:
        return
    print(f"       {ext.get('version', '')}")
    time.sleep(5)
    tab = sv.cmd({"do": "open", "url": "https://soundcloud.com/"})["id"]
    time.sleep(12)
    # The cookie banner's Reject all: its veil sits over the button.
    sv.ev(tab, "(() => { const b = document.querySelector('#onetrust-reject-all-handler'); if (b) b.click(); })(); 1")
    time.sleep(2)
    framed = sv.ev(tab, "performance.getEntriesByType('resource').filter((r) => /secure\\.soundcloud\\.com\\/web-auth/.test(r.name)).length")
    t.ok("with Privacy Badger, SoundCloud's sign-in frame loads", isinstance(framed, (int, float)) and framed >= 1, framed)
    sv.cmd({"do": "tap", "id": tab, "selector": "button.frontHero__loginButton"})
    time.sleep(6)
    shown = sv.ev(tab, "(() => { const w = document.querySelector('.webAuthContainerWrapper'), f = document.querySelector('iframe[src*=\"web-auth\"]');"
                       " return JSON.stringify([w && w.className, f && f.src.split('is_visible=')[1]]); })()")
    t.ok("… and Sign in shows it", json.loads(shown) == ["webAuthContainerWrapper", "true"], shown)


def main():
    t = sv.T()
    sv.APP = probe_copy()
    try:
        sv.setup()
        sv.launch()
        if os.environ.get("SEARCH_BADGER_ONLY") != "1":
            local_part(t)
        if os.environ.get("SEARCH_BADGER") == "1":
            real_badger(t)
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
