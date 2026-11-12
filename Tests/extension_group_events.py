#!/usr/bin/env python3
"""Tab group and idle events reach an extension that listens for them, from
the browser and not from a timer of the shim's (ExtensionWatch.swift), in a
hidden probe.

Build first (`./build.sh debug`), then `python3 Tests/extension_group_events.py`.
It runs a copy of build/Search.app under a bundle id of its own, hidden, in
a world of its own with split_view.py's harness; the copy, its WebKit
folders and the world are removed afterwards.

The shim used to ask the browser for the groups every 3 s and for the idle
state every 15 s, for as long as an extension listened. What is checked, with
an extension that listens to chrome.tabGroups and chrome.idle:

- its listening opens one port for each to the browser, which watches;
- a group made, folded and emptied is told as Chrome tells it
  (onCreated, onUpdated, onRemoved), and a group closed with its tabs too;
- with its listeners removed the browser watches nothing, and a group made
  then is told to nobody; with them added again, it is told again.
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

sv.use("extension-group-events")
BUNDLE = "com.officecommun.search.groupevents"
work = Path(tempfile.mkdtemp(prefix="search-groupevents-"))

FILES = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "Group Events", "version": "1.0",
        "permissions": ["tabGroups", "idle", "storage"],
        "background": {"service_worker": "background.js"},
        "externally_connectable": {"matches": ["http://127.0.0.1/*"]},
    }),
    "background.js": """
// What it was told, kept in storage: a worker may be put away between asks.
let queue = Promise.resolve();
const note = (event) => {
  queue = queue.then(() => chrome.storage.local.get({ events: [] }))
    .then(({ events }) => chrome.storage.local.set({ events: [...events, event] }));
};
const on = {
  created: (g) => note("created:" + g.title),
  updated: (g) => note("updated:" + g.title + ":" + g.collapsed),
  removed: (g) => note("removed:" + g.title),
  idle: (s) => note("idle:" + s),
};
const start = () => {
  chrome.tabGroups.onCreated.addListener(on.created);
  chrome.tabGroups.onUpdated.addListener(on.updated);
  chrome.tabGroups.onRemoved.addListener(on.removed);
  chrome.idle.setDetectionInterval(15);
  chrome.idle.onStateChanged.addListener(on.idle);
};
const stop = () => {
  chrome.tabGroups.onCreated.removeListener(on.created);
  chrome.tabGroups.onUpdated.removeListener(on.updated);
  chrome.tabGroups.onRemoved.removeListener(on.removed);
  chrome.idle.onStateChanged.removeListener(on.idle);
};
start();
chrome.runtime.onMessageExternal.addListener((message, sender, sendResponse) => {
  if (message.type === "start") { start(); sendResponse({ ok: true }); }
  else if (message.type === "stop") { stop(); sendResponse({ ok: true }); }
  else queue.then(() => chrome.storage.local.get({ events: [] })).then((r) => sendResponse(r));
  return true;
});
""",
}

ASK = """(function (ext, type) {
  window.__r = null;
  chrome.runtime.sendMessage(ext, { type }, (r) => { window.__r = r || { none: String(chrome.runtime.lastError && chrome.runtime.lastError.message) }; });
})(%s, %s); 1"""


def probe_copy():
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def ev(id, js):
    return sv.cmd({"do": "eval", "id": id, "js": js}).get("value")


def group(**f): return sv.cmd({"do": "group", **f})


def watching():
    return sv.cmd({"do": "extensions"}).get("watching") or {}


def main():
    t = sv.T()
    folder = work / "ext"
    folder.mkdir()
    for name, body in FILES.items(): (folder / name).write_text(body)
    sv.APP = probe_copy()
    try:
        sv.setup(**{"tabs.groups": True, "start.fresh": False})
        sv.launch()
        sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
        ext = None
        for _ in range(60):
            ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == "Group Events" and x["loaded"]), None)
            if ext: break
            time.sleep(0.25)
        t.ok("the extension loads", ext is not None)
        if not ext: return t

        listed = sv.page("listed")

        def ask(type):
            ev(listed, ASK % (json.dumps(ext["id"]), json.dumps(type)))
            for _ in range(80):
                got = ev(listed, "JSON.stringify(window.__r || null)")
                if got and got != "null": return json.loads(got)
                time.sleep(0.25)
            return None

        def told():
            r = ask("events")
            # Whether the Mac was idle meanwhile is not what is checked here.
            return [e for e in (r or {}).get("events", []) if not e.startswith("idle:")]

        def wait_for(event, within=8):
            began = time.time()
            while time.time() - began < within:
                if event in told(): return time.time() - began
                time.sleep(0.2)
            return None

        def wait_watch(groups, idle, within=10):
            state = {}
            for _ in range(int(within / 0.25)):
                state = watching()
                if state.get("groups") is groups and state.get("idle") is idle: return state
                time.sleep(0.25)
            return state

        # Its listeners are the browser's to watch for, and nobody else's.
        state = wait_watch(True, True)
        t.ok("listening for groups and idleness has the browser watch both", state.get("groups") is True and state.get("idle") is True, state)
        t.ok("each by one port", state.get("ports") == 2, state)
        t.ok("nothing told so far", told() == [], told())

        a, b = sv.page("a"), sv.page("b")
        group(id=a, new=True, name="Reading"); group(id=b, name="Reading")
        t.ok("a group made is told as created, with the name it has", wait_for("created:Reading") is not None, told())
        group(name="Reading", fold=True)
        t.ok("a group folded is told as updated", wait_for("updated:Reading:true") is not None, told())
        group(id=a, name="none"); group(id=b, name="none")
        t.ok("a group emptied is told as removed", wait_for("removed:Reading") is not None, told())

        c = sv.page("c")
        group(id=c, new=True, name="Second")
        t.ok("another group is told as created", wait_for("created:Second") is not None, told())
        group(name="Second", close=True)
        t.ok("a group closed with its tabs is told as removed", wait_for("removed:Second") is not None, told())

        # Listeners gone, the browser watches nothing, and nothing is told.
        ask("stop")
        state = wait_watch(False, False)
        t.ok("no listener left, the browser watches neither", state.get("groups") is False and state.get("idle") is False, state)
        before = told()
        d = sv.page("d")
        group(id=d, new=True, name="Unheard")
        time.sleep(1.5)
        t.ok("a group made then is told to nobody", told() == before, (before, told()))

        # Listening again, it is told again.
        ask("start")
        state = wait_watch(True, True)
        t.ok("listening again has the browser watch again", state.get("groups") is True and state.get("idle") is True, state)
        group(name="Unheard", fold=True)
        t.ok("a change is told again", wait_for("updated:Unheard:true") is not None, told())
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
