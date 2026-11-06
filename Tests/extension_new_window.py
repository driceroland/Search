#!/usr/bin/env python3
"""A window an extension makes, then groups its tab in (#872), in a hidden
probe.

Build first (`./build.sh`), then `python3 Tests/extension_new_window.py`.
It runs a copy of build/Search.app under a bundle id of its own, hidden, in
a world of its own with split_view.py's harness; the copy, its WebKit
folders and the world are removed afterwards.

Claude in Chrome starts by making a window (windows.create, about:blank)
and grouping the first of the tabs it is given back. In Search a window
also holds the space's pins, so that list began with the pins, and the
group was refused. What is checked:

- windows.create gives back the tabs the window was made with first, as
  Chrome's new window holds only those;
- grouping that first tab works, with pins in the space;
- the new window's tab can be found again by its id afterwards, so the
  extension can act on it.
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

sv.use("extension-new-window")
BUNDLE = "com.officecommun.search.newwindow"
work = Path(tempfile.mkdtemp(prefix="search-newwindow-"))

FILES = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "Windowed", "version": "1.0",
        "permissions": ["tabs", "tabGroups"],
        "background": {"service_worker": "background.js"},
        "externally_connectable": {"matches": ["http://127.0.0.1/*"]},
    }),
    "background.js": """
chrome.runtime.onMessageExternal.addListener((message, sender, sendResponse) => {
  (async () => {
    const out = {};
    try {
      const w = await chrome.windows.create({ url: "about:blank", focused: true });
      out.tabs = (w.tabs || []).map((t) => ({ index: t.index, pinned: !!t.pinned, url: t.url || t.pendingUrl || "" }));
      try {
        const id = await chrome.tabs.group({ tabIds: [w.tabs[0].id], createProperties: { windowId: w.id } });
        await chrome.tabGroups.update(id, { title: "Claude" });
        const t = await chrome.tabs.get(w.tabs[0].id);
        out.group = id; out.groupOf = t.groupId; out.pinnedOf = !!t.pinned;
      } catch (e) { out.groupError = String(e && e.message || e); }
      await chrome.windows.remove(w.id).catch(() => {});
    } catch (e) { out.error = String(e && e.message || e); }
    sendResponse(out);
  })();
  return true;
});
""",
}

ASK = """(function (ext) {
  window.__r = null;
  chrome.runtime.sendMessage(ext, { type: "win" }, (r) => { window.__r = r || { none: String(chrome.runtime.lastError && chrome.runtime.lastError.message) }; });
})(%s); 1"""


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


def main():
    t = sv.T()
    folder = work / "ext"
    folder.mkdir()
    for name, body in FILES.items(): (folder / name).write_text(body)
    sv.APP = probe_copy()
    try:
        sv.setup(sidebar=True)
        sv.launch()
        sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
        ext = None
        for _ in range(60):
            ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == "Windowed" and x["loaded"]), None)
            if ext: break
            time.sleep(0.25)
        t.ok("the extension loads", ext is not None)
        if not ext: return t

        # Two pins in the space, as Search's every window then shows.
        for name in ("pin-one", "pin-two"):
            sv.cmd({"do": "pin", "id": sv.page(name)})
        listed = sv.page("listed")
        time.sleep(1)

        ev(listed, ASK % json.dumps(ext["id"]))
        r = None
        for _ in range(60):
            got = ev(listed, "JSON.stringify(window.__r || null)")
            if got and got != "null": r = json.loads(got); break
            time.sleep(0.25)
        tabs = (r or {}).get("tabs") or []
        t.ok("windows.create answers", r is not None and not r.get("error"), r)
        t.ok("the tab the window was made with comes first, not a pin",
             tabs and not tabs[0]["pinned"] and tabs[0]["url"] in ("about:blank", ""), tabs)
        t.ok("the pins are still listed, after it", sum(1 for x in tabs if x["pinned"]) == 2, tabs)
        t.ok("grouping that first tab works", r and r.get("group") is not None and r.get("groupOf") == r.get("group")
             and not r.get("groupError"), r)
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
