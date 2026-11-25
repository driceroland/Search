#!/usr/bin/env python3
"""An extension's popup whose content waits on its worker isn't shrunk to a
speck meanwhile (idea 1179), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/extension_popup_slow.py`.
It runs a copy of build/Search.app under a bundle id of its own, hidden, in
a world of its own; the copy, its WebKit folders and the world are removed
afterwards.

NordPass's popup is an empty page until its worker answers. A second after
the page loaded, Search measured it regardless; empty, it is the least a
popup can be, 25 × 25, and the popover shrank to that and kept it as the
popup's size for next time: it came up at its old size for a moment, then
as nothing, and every opening after started as nothing. Two popups, each
built only once their worker answers:

- slow: the worker answers after 4 s; the popover is never the 25-point
  square, and is 360 × 500 once built;
- never: the page is never built; the popover is never the 25-point
  square, and the size kept for next time isn't either.
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

sv.use("extension-popup-slow")
BUNDLE = "com.officecommun.search.popupslow"
work = Path(tempfile.mkdtemp(prefix="search-popupslow-"))

POPUP = """<!doctype html><html><head><title>p</title><style>body{margin:0}</style></head>
<body><div id=root></div><script src=popup.js></script></body></html>"""
POPUP_JS = """chrome.runtime.sendMessage("hello").then(() => {
  document.getElementById("root").innerHTML = '<div style="width:360px;height:500px;background:#eef">Vault</div>';
});"""
WORKER = {"slow": 'chrome.runtime.onMessage.addListener((m, s, reply) => { setTimeout(() => reply("ok"), 4000); return true; });',
          "never": 'chrome.runtime.onMessage.addListener(() => true);'}
NEVER_JS = "new Promise(() => {});"


def probe_copy():
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def popup(id, js):
    try:
        return sv.cmd({"do": "ext-popup", "id": id, "js": js})
    except RuntimeError:
        return None


def loaded(name, within=60):
    end = time.time() + within
    while time.time() < end:
        ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == name and x["loaded"]), None)
        if ext: return ext
        time.sleep(0.25)
    return None


def watch(id, seconds):
    """(t, width, height, shown) of the popover, every quarter second."""
    out, start = [], time.time()
    while time.time() - start < seconds:
        p = (popup(id, "1") or {}).get("popover") or {}
        if p:
            w, h = p.get("size", [0, 0])
            out.append((round(time.time() - start, 2), w, h, p.get("shown")))
        time.sleep(0.25)
    return out


def kept(id):
    out = subprocess.run(["defaults", "export", sv.SUITE, "-"], capture_output=True).stdout
    import plistlib
    try: return (plistlib.loads(out).get("extensionPopupSizes") or {}).get(id)
    except Exception: return None


def main():
    t = sv.T()
    ids = {}
    for name, worker in WORKER.items():
        folder = work / name
        folder.mkdir()
        (folder / "manifest.json").write_text(json.dumps({"manifest_version": 3, "name": f"Slow {name}", "version": "1.0",
                                                          "background": {"service_worker": "bg.js"},
                                                          "action": {"default_popup": "popup.html"}}))
        (folder / "popup.html").write_text(POPUP)
        (folder / "popup.js").write_text(POPUP_JS if name == "slow" else NEVER_JS)
        (folder / "bg.js").write_text(worker)
    sv.APP = probe_copy()
    try:
        sv.setup(sidebar=True)
        sv.launch()
        sv.cmd({"do": "ext-answer", "answer": "yes"})
        for name in WORKER:
            sv.cmd({"do": "ext-folder", "path": str(work / name), "yes": True})
            ext = loaded(f"Slow {name}")
            t.ok(f"{name}: loads", ext is not None)
            if ext:
                ids[name] = ext["id"]
                sv.cmd({"do": "ext-pin", "id": ext["id"], "on": True})
        sv.page("site"); time.sleep(1)
        for name, id in ids.items():
            sv.cmd({"do": "ext-press", "id": id})
            s = watch(id, 7.0)
            print(f"{name}:", s)
            t.ok(f"{name}: never the 25-point square", all(x[1] > 25 or x[2] > 25 for x in s), s)
            if name == "slow":
                t.ok("slow: 360 × 500 once its worker answered", s and abs(s[-1][1] - 360) <= 3 and abs(s[-1][2] - 500) <= 3, s[-1:])
            k = kept(id)
            t.ok(f"{name}: the size kept for next time isn't the 25-point square", not k or max(k) > 25, k)
            sv.cmd({"do": "ext-press", "id": id}); time.sleep(0.8)
    finally:
        sv.finish()
        for kind in ("WebKit", "Caches", "HTTPStorages"):
            shutil.rmtree(Path.home() / "Library" / kind / BUNDLE, ignore_errors=True)
        shutil.rmtree(work, ignore_errors=True)
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
