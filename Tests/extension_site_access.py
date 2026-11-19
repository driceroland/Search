#!/usr/bin/env python3
"""Settings › Extensions › Runs on (#698), in a hidden probe: an extension
held to some sites runs its content script on those and not elsewhere, and
one held to "on click" runs nowhere until its button is pressed, then on
that tab's site only until the tab leaves it.

Build first (`./build.sh debug`), then, one probe at a time,
`lockf -t 900 /private/tmp/claude-501/search-probe.lock python3 Tests/extension_site_access.py`.
It runs a copy of build/Search.app under a bundle id of its own, hidden, in
a world of its own with split_view.py's harness; the copy, its WebKit
folders and the world are removed afterwards.

The two sites are split_view.py's page server under two names, 127.0.0.1
and localhost: match patterns don't look at ports, so one server serves both.
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

sv.use("extension-site-access")
BUNDLE = "com.officecommun.search.siteaccess"
work = Path(tempfile.mkdtemp(prefix="search-siteaccess-"))
PORT = sv.srv.server_port
A = f"http://127.0.0.1:{PORT}"
B = f"http://localhost:{PORT}"

FILES = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "Sites", "version": "1.0",
        "host_permissions": ["<all_urls>"],
        "action": {"default_title": "Sites"},
        "background": {"service_worker": "worker.js"},
        "content_scripts": [{"matches": ["<all_urls>"], "js": ["content.js"], "run_at": "document_end"}],
    }),
    # How many times it ran in this page, and what the worker heard of
    # permissions taken back.
    "content.js": """
const root = document.documentElement;
root.setAttribute('data-ran', String(Number(root.getAttribute('data-ran') || 0) + 1));
chrome.runtime.sendMessage('removed', (list) => root.setAttribute('data-removed', JSON.stringify(list || [])));
""",
    "worker.js": """
const removed = [];
chrome.permissions.onRemoved.addListener((p) => removed.push(...(p.origins || [])));
chrome.runtime.onMessage.addListener((m, _s, reply) => { if (m === 'removed') reply(removed); });
chrome.action.onClicked.addListener(() => {});
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


def opened(url, settle=1.2):
    page = sv.sp("open", url=url)["resultID"]
    time.sleep(settle)
    return page


def ran(page, within=4.0):
    """The page's count once it has had time to run; '' when it never did."""
    end = time.time() + within
    value = attr(page, "ran")
    while not value and time.time() < end:
        time.sleep(0.25)
        value = attr(page, "ran")
    return value


def sites(id, **f):
    return sv.cmd({"do": "ext-sites", "id": id, **f})


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
            ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == "Sites" and x["loaded"]), None)
            if ext: break
            time.sleep(0.25)
        t.ok("the extension loads", ext is not None)
        if not ext: return t
        id = ext["id"]

        # The default: every site, as before.
        state = sites(id)
        t.ok("it runs on all sites until told otherwise", state["mode"] == "all", state)
        a0, b0 = opened(f"{A}/all-a"), opened(f"{B}/all-b")
        t.ok("on all sites: runs on both", ran(a0) == "1" and ran(b0) == "1", (ran(a0), ran(b0)))

        # Some sites: 127.0.0.1 only.
        state = sites(id, mode="some", hosts=["127.0.0.1"])
        t.ok("some sites: only the named one granted", "*://127.0.0.1/*" in state["granted"]
             and not any(p in state["granted"] for p in ("<all_urls>", "*://*/*")), state["granted"])
        a1, b1 = opened(f"{A}/some-a"), opened(f"{B}/some-b")
        t.ok("some sites: runs on the named site", ran(a1) == "1", ran(a1))
        t.ok("some sites: doesn't run on the other", ran(b1, within=2.5) == "", ran(b1))
        removed = json.loads(attr(a1, "removed") or "[]")
        t.ok("the extension is told what it lost (permissions.onRemoved)", "<all_urls>" in removed, removed)
        t.ok("a page open on the site it lost is left as it was, not reloaded", ran(b0) == "1", ran(b0))

        # On click: nowhere, until its button is pressed on a tab.
        state = sites(id, mode="click")
        t.ok("on click: no site granted", not [p for p in state["granted"] if "chromiumapp" not in p], state["granted"])
        b2 = opened(f"{B}/click-b")
        t.ok("on click: doesn't run before the click", ran(b2, within=2.5) == "", ran(b2))
        sv.cmd({"do": "ext-press", "id": id})
        time.sleep(1.0)
        t.ok("on click: runs in the page once pressed, without a reload", ran(b2) == "1", ran(b2))
        state = sites(id)
        t.ok("on click: that site is granted for the tab", "*://localhost/*" in state["granted"]
             and state["clicked"] == ["localhost"], state)
        b3 = opened(f"{B}/click-b-again")
        t.ok("on click: a same-site tab opened now has it too (a site, not a tab, to WebKit)", ran(b3) == "1", ran(b3))
        # The pressed tab goes to another site: the grant goes with it.
        sv.cmd({"do": "eval", "id": b2, "js": f"location.href = '{A}/click-left'"})
        time.sleep(1.5)
        t.ok("on click: the other site isn't reached by the old click", ran(b2, within=2.5) == "", ran(b2))
        state = sites(id)
        t.ok("on click: the tab that left gave its grant back", state["clicked"] == [], state)
        b4 = opened(f"{B}/click-b-later")
        t.ok("on click: the site is no longer reached after the tab left", ran(b4, within=2.5) == "", ran(b4))

        # Run on This Site (the right-click), on the tab in front.
        state = sites(id, here=True)
        t.ok("Run on This Site: runs in the page in front", ran(b4) == "1" and state["runsHere"], (ran(b4), state))

        # And back to every site.
        state = sites(id, mode="all")
        a5 = opened(f"{A}/back-a")
        t.ok("back to all sites: runs everywhere again", ran(a5) == "1" and "<all_urls>" in state["granted"], (ran(a5), state["granted"]))
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
