#!/usr/bin/env python3
"""A store update that needs a new OK is shown, not dropped (idea 1147).

Needs the network (the Chrome Web Store). Build first (`./build.sh`), then
`python3 Tests/extension_update_held.py`. Like extension_store_update.py it
runs a copy of build/Search.app under a bundle id of its own, hidden, in a
world of its own; everything is removed afterwards. Nothing is signed into.

Bitwarden is installed from the store; Search is quit, its version is set
back to 2026.10.2 and one of the grants written down for it is taken away,
as when it was added under a Search or macOS that described it a little
differently. The update then asks for "more" than it was allowed:

- with no window to ask on (the browser hidden, or every window minimized)
  the question isn't put. Before this fix the update was dropped there and
  then, the day's check recorded as done, and nothing anywhere said so: a
  browser left in the background never updated it;
- now the update is held and says so (Settings › Extensions: "update …
  waiting for your OK", with Review Update…), still after a relaunch;
- answered yes, it is taken in and the hold is gone.
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

sv.use("extension-update-held")
BUNDLE = "com.officecommun.search.updateheld"
BW = "nngceckbapebfimnlniiiahkandclblb"
OLD = "2026.10.2"
work = Path(tempfile.mkdtemp(prefix="search-updateheld-"))


def probe_copy():
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def ext():
    return {x["id"]: x for x in sv.cmd({"do": "extensions"})["extensions"]}.get(BW)


def wait_loaded(within=120):
    end = time.time() + within
    while time.time() < end:
        e = ext()
        if e and e["loaded"]: return e
        time.sleep(1)
    return ext()


def main():
    t = sv.T()
    sv.APP = probe_copy()
    try:
        sv.setup()
        sv.launch()
        sv.cmd({"do": "ext-answer", "answer": "yes"})
        sv.cmd({"do": "ext-add", "id": BW, "yes": True})
        e = wait_loaded()
        t.ok("Bitwarden installs from the store", e and e["loaded"], e)
        if not e: return t
        latest = e["version"]
        sv.quit(); time.sleep(1)

        folder = Path(sv.SUPPORT) / "Extensions"
        lst = folder / "installed.json"
        data = json.loads(lst.read_text())
        for item in data:
            if item["id"] == BW:
                item["version"] = OLD
                dropped = item["permissions"].pop(0)
        lst.write_text(json.dumps(data))
        manifest = folder / BW / "manifest.json"
        m = json.loads(manifest.read_text()); m["version"] = OLD; manifest.write_text(json.dumps(m))
        subprocess.run(["defaults", "delete", sv.SUITE, "extensions.checked"], capture_output=True)

        sv.launch()
        sv.cmd({"do": "ext-answer", "answer": "ask"})  # really ask: hidden, there is no window to ask on
        wait_loaded()
        state = sv.cmd({"do": "ext-check"})  # waits for the launch round
        time.sleep(3)  # the question runs after the round
        e = ext()
        asked = sv.cmd({"do": "ext-answer", "answer": "ask"}).get("asked")
        t.ok(f"the update wants more than was written down ({dropped}) and is not taken in unasked",
             e["version"] == OLD, (e["version"], asked))
        t.ok("the launch check ran and is recorded as done", state["failures"] == 0 and state["retryIn"] is None, state)
        t.ok("the held update is shown, with its version", e.get("held") == latest, e.get("held"))

        sv.quit(); time.sleep(1)
        sv.launch()
        wait_loaded()
        t.ok("still shown after a relaunch, before the next check", ext().get("held") == latest, ext().get("held"))

        sv.cmd({"do": "ext-answer", "answer": "yes"})
        s = sv.cmd({"do": "ext-check", "age": 21 * 3600})
        end = time.time() + 120
        while time.time() < end and ext()["version"] == OLD: time.sleep(2)
        e = ext()
        t.ok("answered yes, the update is taken in", e["version"] == latest, (e["version"], s))
        t.ok("and the hold is gone", not e.get("held"), e.get("held"))
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
