#!/usr/bin/env python3
"""chrome.management answers as Chrome would for the calling extension's
permissions (#1431): with "management", getAll() lists every installed
extension, the calling one included, and get(id) finds any of them; without
it, getSelf() still answers but getAll() and get() of another are refused.

Build first (`./build.sh`), then `python3 Tests/extension_management.py`. A
copy of build/Search.app under a bundle id of its own, hidden, in a world of
its own; the copy, its WebKit folders and the world are removed afterwards.

Three local extensions: Manager (with "management", as Extension Manager
has), Plain (without), and Sleeper (turned off in Settings › Extensions,
listed with enabled false, as Chrome lists a disabled one).
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

sv.use("extension-management")
BUNDLE = "com.officecommun.search.extmanagement"
work = Path(tempfile.mkdtemp(prefix="search-ext-management-"))


def extension(name, permissions):
    return {
        "manifest.json": json.dumps({
            "manifest_version": 3, "name": name, "version": "1.2", "description": name + " test",
            "permissions": permissions, "background": {"service_worker": "sw.js"},
        }),
        "sw.js": "",
        "page.html": "<!doctype html><title>" + name + "</title><p>page</p>",
    }


def probe_copy():
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def install(name, permissions):
    folder = work / name
    for file, body in extension(name, permissions).items():
        (folder / file).parent.mkdir(parents=True, exist_ok=True)
        (folder / file).write_text(body)
    sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
    for _ in range(40):
        ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == name and x["loaded"]), None)
        if ext: return ext
        time.sleep(0.5)
    return None


CALL = """(async () => { const r = {};
  const run = async (k, f) => { try { r[k] = await f(); } catch (e) { r[k] = 'threw: ' + (e && e.message || e); } };
  await run('self', () => chrome.management.getSelf());
  await run('all', () => chrome.management.getAll());
  await run('other', () => chrome.management.get(%s));
  await run('mine', () => chrome.management.get(chrome.runtime.id));
  window.__got = JSON.stringify(r); })(); 1"""


def ask(ext_id, other_id):
    page = sv.cmd({"do": "ext-page", "id": ext_id, "path": "page.html"})["id"]
    time.sleep(2)
    sv.ev(page, CALL % json.dumps(other_id))
    for _ in range(30):
        got = sv.ev(page, "window.__got || null")
        if got: return json.loads(got)
        time.sleep(0.3)
    return {}


def main():
    t = sv.T()
    sv.APP = probe_copy()
    try:
        sv.setup()
        sv.launch()
        sv.cmd({"do": "ext-answer", "answer": "yes"})
        manager = install("Manager", ["management", "storage"])
        plain = install("Plain", ["storage"])
        sleeper = install("Sleeper", ["storage"])
        t.ok("the three extensions load", None not in (manager, plain, sleeper))
        if None in (manager, plain, sleeper): return t
        sv.cmd({"do": "ext-enable", "id": sleeper["id"], "on": False})
        time.sleep(1)

        got = ask(manager["id"], plain["id"])
        listed = got.get("all")
        t.ok("with management, getAll() is a list", isinstance(listed, list), got.get("all"))
        listed = listed if isinstance(listed, list) else []
        by_name = {x.get("name"): x for x in listed}
        t.ok("…of every installed extension, itself included", set(by_name) == {"Manager", "Plain", "Sleeper"}, sorted(by_name))
        t.ok("…each of type extension, as Extension Manager keeps", all(x.get("type") == "extension" for x in listed), listed)
        t.ok("…with its id, version and description",
             by_name.get("Plain", {}).get("id") == plain["id"] and by_name["Plain"].get("version") == "1.2"
             and by_name["Plain"].get("description") == "Plain test", by_name.get("Plain"))
        t.ok("a turned-off one is listed with enabled false", by_name.get("Sleeper", {}).get("enabled") is False
             and by_name.get("Plain", {}).get("enabled") is True, by_name.get("Sleeper"))
        t.ok("the caller's own entry names its permissions", "management" in by_name.get("Manager", {}).get("permissions", []),
             by_name.get("Manager"))
        t.ok("get(another's id) finds that one", isinstance(got.get("other"), dict) and got["other"].get("name") == "Plain", got.get("other"))
        t.ok("getSelf() is itself", isinstance(got.get("self"), dict) and got["self"].get("id") == manager["id"], got.get("self"))

        got = ask(plain["id"], manager["id"])
        t.ok("without management, getSelf() still answers", isinstance(got.get("self"), dict) and got["self"].get("name") == "Plain",
             got.get("self"))
        t.ok("…getAll() is refused", str(got.get("all")).startswith("threw"), got.get("all"))
        t.ok("…and get() of another is refused", str(got.get("other")).startswith("threw"), got.get("other"))
        t.ok("…while get() of its own id answers", isinstance(got.get("mine"), dict) and got["mine"].get("id") == plain["id"],
             got.get("mine"))
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
