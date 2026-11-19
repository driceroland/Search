#!/usr/bin/env python3
"""runtime.onInstalled across relaunches, in a hidden probe.

Build first (`./build.sh debug`), then
`python3 Tests/extension_installed_reason.py`. It runs a copy of
build/Search.app under a bundle id of its own, hidden, in a world of its own
with split_view.py's harness; the copy, its WebKit folders and the world are
removed afterwards.

Extensions open their welcome or setup tab from runtime.onInstalled when the
reason is "install". Some opened it again on every launch of Search. What is
checked, with an extension that notes every onInstalled it hears in
storage.local and opens a tab on "install":

- installing it says "install", once, and opens its tab — even right after
  launch, where WebKit counts any load as the browser starting;
- quitting and launching again in the same world says nothing (Chrome fires
  no onInstalled on a browser start), opens no tab, and storage.local kept
  what it had;
- switched off, Search launched again, and switched on more than five
  seconds later — where WebKit says "install" for any load of the same
  version, as for one that loads late at launch — it says nothing either;
- a new version, taken up with Reload, says "update" with the version before;
- a Reload of the same version says "update" too, as Chrome does, never
  "install";
- a launch after that again says nothing.
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

sv.use("extension-installed-reason")
BUNDLE = "com.officecommun.search.installedreason"
work = Path(tempfile.mkdtemp(prefix="search-installedreason-"))
NAME = "Welcomes"

BACKGROUND = """
chrome.runtime.onInstalled.addListener(async (details) => {
  const { heard = [] } = await chrome.storage.local.get("heard");
  heard.push({ reason: details.reason, previousVersion: details.previousVersion || null,
               version: chrome.runtime.getManifest().version });
  await chrome.storage.local.set({ heard });
  if (details.reason === "install") chrome.tabs.create({ url: WELCOME });
});
chrome.runtime.onStartup.addListener(async () => {
  const { started = 0 } = await chrome.storage.local.get("started");
  await chrome.storage.local.set({ started: started + 1 });
});
"""


def write(folder, version):
    folder.mkdir(exist_ok=True)
    (folder / "manifest.json").write_text(json.dumps({
        "manifest_version": 3, "name": NAME, "version": version,
        "permissions": ["storage", "tabs"],
        "background": {"service_worker": "background.js"},
    }))
    (folder / "background.js").write_text(f"const WELCOME = {json.dumps(sv.BASE + '/welcome')};\n" + BACKGROUND)


def probe_copy():
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def loaded():
    for _ in range(80):
        ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == NAME and x["loaded"]), None)
        if ext: return ext
        time.sleep(0.25)
    return None


def welcomes():
    return sum(1 for x in sv.cmd({"do": "tabs"})["tabs"] if "/welcome" in (x.get("url") or ""))


def stored(id):
    """storage.local, read from one of the extension's own pages."""
    page = sv.cmd({"do": "ext-page", "id": id, "path": "background.js"})["id"]
    time.sleep(1)
    js = "(() => { chrome.storage.local.get(null).then((r) => window.__r = r); return JSON.stringify(window.__r || null); })()"
    value = None
    for _ in range(20):
        value = json.loads(sv.cmd({"do": "eval", "id": page, "js": js}).get("value") or "null")
        if value is not None: break
        time.sleep(0.25)
    sv.cmd({"do": "close", "id": page})
    return value or {}


def settle(id, count, within=8):
    """What it heard, once it has heard `count` things or a while has passed."""
    end = time.time() + within
    while True:
        s = stored(id)
        if len(s.get("heard", [])) >= count or time.time() > end: return s
        time.sleep(0.5)


def main():
    t = sv.T()
    folder = work / "ext"
    write(folder, "1.0")
    sv.APP = probe_copy()
    try:
        sv.setup()
        sv.launch()
        sv.cmd({"do": "ext-answer", "answer": "yes"})
        sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
        ext = loaded()
        t.ok("the extension loads", ext is not None)
        if not ext: return t
        id = ext["id"]
        s = settle(id, 1)
        first = s.get("heard", [])
        t.ok("installing says install", [h["reason"] for h in first] == ["install"], s)
        time.sleep(1)
        t.ok("installing opens its tab", welcomes() == 1, welcomes())
        sv.cmd({"do": "eval", "id": sv.page("blank"), "js": "1"})

        for n in (1, 2):
            sv.quit(); time.sleep(1)
            sv.launch()
            t.ok(f"launch {n}: loads again", loaded() is not None)
            time.sleep(4)
            s = stored(id)
            t.ok(f"launch {n}: says no install or update", s.get("heard", []) == first, s.get("heard"))
            t.ok(f"launch {n}: no welcome tab", welcomes() <= 1, welcomes())
            t.ok(f"launch {n}: storage.local kept", bool(first) and s.get("heard") == first, s)

        # Off, a launch, and on again once WebKit's first five seconds are
        # over: the load WebKit calls an install.
        sv.cmd({"do": "ext-enable", "id": id, "on": False}); time.sleep(1)
        sv.quit(); time.sleep(1)
        sv.launch(); time.sleep(6)
        sv.cmd({"do": "ext-enable", "id": id, "on": True})
        t.ok("switched on late: loads", loaded() is not None)
        time.sleep(4)
        s = stored(id)
        t.ok("switched on late: says no install", s.get("heard", []) == first, s.get("heard"))
        t.ok("switched on late: no welcome tab", welcomes() <= 1, welcomes())

        write(folder, "2.0")
        sv.cmd({"do": "ext-reload", "id": id})
        time.sleep(2); loaded()
        s = settle(id, len(first) + 1)
        heard = s.get("heard", [])
        t.ok("a new version says update from the old one",
             heard[:len(first)] == first and [(h["reason"], h["previousVersion"]) for h in heard[len(first):]] == [("update", "1.0")], heard)

        sv.cmd({"do": "ext-reload", "id": id})
        time.sleep(2); loaded()
        s = settle(id, len(first) + 2)
        heard = s.get("heard", [])
        t.ok("a reload of the same version says update", [h["reason"] for h in heard[len(first):]] == ["update", "update"], heard)

        sv.quit(); time.sleep(1)
        sv.launch()
        loaded(); time.sleep(4)
        s = stored(id)
        t.ok("a launch after the update says nothing", len(s.get("heard", [])) == len(heard), s.get("heard"))
        t.ok("no welcome tab after all that", welcomes() <= 1, welcomes())
    finally:
        sv.finish()
        for kind in ("WebKit", "Caches", "HTTPStorages"):
            shutil.rmtree(Path.home() / "Library" / kind / BUNDLE, ignore_errors=True)
        shutil.rmtree(work, ignore_errors=True)
    return t


if __name__ == "__main__":
    result = main()
    result.done()
    sys.exit(1 if result.failed else 0)
