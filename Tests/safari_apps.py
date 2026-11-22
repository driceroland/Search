#!/usr/bin/env python3
"""Settings › Extensions › From Safari apps (SafariApps.swift, idea 888), in a
hidden probe.

Build first (`./build.sh`), then `python3 Tests/safari_apps.py`. A copy of
build/Search.app under a bundle id of its own, hidden, in a world of its own
(split_view.py's harness); the copy, its WebKit folders and the world are
removed afterwards.

Apps made here, in a folder of this run's:
- Kit.app carries a Safari web extension (its .appex says
  com.apple.Safari.web-extension, its Resources hold a manifest.json and a
  worker), a Safari content blocker (another point, no manifest) and a
  "web extension" whose Resources is a link out of the app;
- Tools/Nested.app, one folder down, carries another.
What is checked:
- the switch is off unless turned on;
- only the two web extensions are listed, named from their manifests, each
  with the folder inside its app; not the content blocker, not the link out;
- Add (the unpacked-extension path) loads one; its worker runs, and its
  `sendNativeMessage` to its own app is refused: nothing of the app runs;
- the app's files are exactly as they were, bytes and dates;
- with SEARCH_REAL_SAFARI=1, the same for the first one found in
  /Applications (read only, as above).
"""
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("safari-apps")
BUNDLE = "com.officecommun.search.safariapps"
work = Path(tempfile.mkdtemp(prefix="search-safari-apps-"))


def probe_copy():
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


WORKER = """
self.ran = 'yes';
chrome.storage.local.set({ ran: 'yes' });
chrome.runtime.sendNativeMessage('com.example.kit', { hello: 1 })
  .then((r) => chrome.storage.local.set({ native: 'answered ' + JSON.stringify(r) }),
        (e) => chrome.storage.local.set({ native: 'refused: ' + String(e && e.message || e) }));
"""


def appex(app, name, point, manifest=None, link_to=None):
    ex = app / "Contents/PlugIns" / f"{name}.appex" / "Contents"
    ex.mkdir(parents=True)
    with open(ex / "Info.plist", "wb") as f:
        plistlib.dump({"CFBundleIdentifier": f"com.example.{name}", "NSExtension": {"NSExtensionPointIdentifier": point}}, f)
    (ex / "MacOS").mkdir()
    (ex / "MacOS" / name).write_text("#!/bin/sh\ntouch " + str(work / f"{name}-ran") + "\n")
    os.chmod(ex / "MacOS" / name, 0o755)
    if link_to:
        os.symlink(link_to, ex / "Resources")
        return
    res = ex / "Resources"
    res.mkdir()
    if manifest:
        (res / "manifest.json").write_text(json.dumps(manifest))
        (res / "sw.js").write_text(WORKER)
        (res / "page.html").write_text("<!doctype html><title>kit page</title>")
    else:
        (res / "blockerList.json").write_text('[{"trigger":{"url-filter":"ads"},"action":{"type":"block"}}]')


def make_apps(root):
    kit = root / "Kit.app"
    (kit / "Contents/MacOS").mkdir(parents=True)
    with open(kit / "Contents/Info.plist", "wb") as f:
        plistlib.dump({"CFBundleIdentifier": "com.example.kit", "CFBundleName": "Kit"}, f)
    mv3 = {"manifest_version": 3, "name": "Kit Helper", "version": "1.0",
           "permissions": ["storage", "nativeMessaging"], "background": {"service_worker": "sw.js"}}
    appex(kit, "KitWeb", "com.apple.Safari.web-extension", mv3)
    appex(kit, "KitBlocker", "com.apple.Safari.content-blocker")
    outside = root / "outside"
    outside.mkdir()
    (outside / "manifest.json").write_text(json.dumps({**mv3, "name": "Link Out"}))
    appex(kit, "KitLinked", "com.apple.Safari.web-extension", link_to=str(outside))
    nested = root / "Tools" / "Nested.app"
    (nested / "Contents/MacOS").mkdir(parents=True)
    appex(nested, "NestedWeb", "com.apple.Safari.web-extension", {**mv3, "name": "__MSG_name__"})
    return kit


def tree(app):
    """Every file under the app: its bytes' hash and its modification time."""
    out = {}
    for dirpath, dirnames, filenames in os.walk(app, followlinks=False):
        for n in filenames + [d for d in dirnames if os.path.islink(os.path.join(dirpath, d))]:
            p = os.path.join(dirpath, n)
            st = os.lstat(p)
            data = b"" if os.path.islink(p) else open(p, "rb").read()
            out[os.path.relpath(p, app)] = (hashlib.sha256(data).hexdigest(), st.st_mtime_ns)
    return out


def loaded(id, within=30):
    end = time.time() + within
    while time.time() < end:
        ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["id"] == id), None)
        if ext and ext["loaded"]:
            return ext
        time.sleep(0.25)
    return None


def stored(id, key, within=20):
    end = time.time() + within
    page = sv.cmd({"do": "ext-page", "id": id, "path": "page.html"})["id"] if True else None
    try:
        while time.time() < end:
            try:
                sv.ev(page, f"chrome.storage.local.get('{key}').then((o) => window.__v = o['{key}']); 1")
                time.sleep(0.4)
                v = sv.ev(page, "window.__v")
                if v:
                    return v
            except RuntimeError:
                time.sleep(0.4)
        return None
    finally:
        sv.cmd({"do": "close", "id": page})


def main():
    t = sv.T()
    sv.APP = probe_copy()
    apps = work / "Applications"
    apps.mkdir()
    kit = make_apps(apps)
    before = tree(apps)
    try:
        sv.setup()
        sv.launch()
        got = sv.cmd({"do": "ext-safari", "in": [str(apps)]})
        print(f"       {got}")
        t.ok("off unless turned on", got["on"] is False, got)
        found = got["found"]
        names = sorted(f["name"] for f in found)
        t.ok("lists the two web extensions, named from their manifests or apps", names == ["Kit Helper", "Nested"], names)
        kitweb = next((f for f in found if f["name"] == "Kit Helper"), None)
        real = os.path.realpath(kit)
        t.ok("… with the folder inside its app", bool(kitweb) and kitweb["folder"] == os.path.join(real, "Contents/PlugIns/KitWeb.appex/Contents/Resources"), kitweb)
        t.ok("not the content blocker, nor the one linked out of its app",
             not any(f["folder"].endswith(("KitBlocker.appex/Contents/Resources", "outside")) for f in found), found)

        sv.cmd({"do": "ext-folder", "path": kitweb["folder"], "yes": True})
        ext = loaded(kitweb["id"])
        t.ok("Add loads it, under the id the card names", ext is not None, ext)
        if ext:
            t.ok("its worker runs", stored(ext["id"], "ran") == "yes")
            native = stored(ext["id"], "native")
            t.ok("its sendNativeMessage to its app is refused", isinstance(native, str) and native.startswith("refused"), native)
            listed = sv.cmd({"do": "ext-safari", "in": [str(apps)]})["found"]
            t.ok("listed again once added, same id", any(f["id"] == ext["id"] for f in listed), listed)
        t.ok("nothing of the apps ran", not list(work.glob("*-ran")), list(work.glob("*-ran")))
        t.ok("the apps' files are as they were, bytes and dates", tree(apps) == before)

        if os.environ.get("SEARCH_REAL_SAFARI"):
            real_found = sv.cmd({"do": "ext-safari"})["found"]
            print(f"       on this Mac: {[(f['app'], f['name']) for f in real_found]}")
            t.ok("finds a Safari extension in /Applications", bool(real_found), real_found)
            if real_found:
                first = real_found[0]
                app = first["folder"].split(".app/")[0] + ".app"
                was = tree(app)
                sv.cmd({"do": "ext-folder", "path": first["folder"], "yes": True})
                ext = loaded(first["id"], within=60)
                t.ok(f"{first['name']} from {first['app']} loads", ext is not None and not ext["failure"], ext)
                time.sleep(3)
                if ext:
                    print(f"       errors: {ext['errors'][:3]} {ext['reported'][:3]}")
                t.ok(f"{first['app']}'s files are as they were", tree(app) == was)
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
