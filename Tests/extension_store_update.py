#!/usr/bin/env python3
"""Store extensions update, and a failed check is tried again soon (idea 992).

Needs the network (the Chrome Web Store). Build first (`./build.sh`), then
`python3 Tests/extension_store_update.py`. It runs a copy of build/Search.app
under a bundle id of its own, hidden, in a world of its own with
split_view.py's harness; the copy, its WebKit folders and the world are
removed afterwards. Nothing is signed into.

Bitwarden and uBlock Origin Lite are installed from the store; Search is
quit, and Bitwarden's version is set back to 2026.10.2 (its manifest and
installed.json), as a copy installed before 19 Nov 2026 has it. Then:

- a check at launch (the store's update check runs once extensions are up)
  brings Bitwarden to the store's version, at least 2026.11.0. Asked
  without installsource=ondemand, the store said "noupdate" for it;
- it is loaded afterwards, its worker runs and its popup page draws its
  app root; it asked nothing (no more access than before);
- uBlock Origin Lite, up to date, is left as it was (same version, same
  folder, untouched files);
- the check is recorded only once it worked: a check that can't reach the
  store (`ext-check` pointed at a port that refuses) leaves the last good
  check as it was and plans a retry an hour on; it isn't run again before
  then; an hour on it is, fails again and waits two hours; back on the
  store it works, and the retry is dropped.
"""
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("extension-store-update")
BUNDLE = "com.officecommun.search.storeupdate"
BW, UBOL = "nngceckbapebfimnlniiiahkandclblb", "ddkjiahejlhfcafbddmgiahcphecmpfh"
OLD = "2026.10.2"
work = Path(tempfile.mkdtemp(prefix="search-storeupdate-"))


def probe_copy():
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def exts():
    return {x["id"]: x for x in sv.cmd({"do": "extensions"})["extensions"]}


def loaded(ids, within=120):
    end = time.time() + within
    while True:
        e = exts()
        if all(i in e and e[i]["loaded"] for i in ids) or time.time() > end: return e
        time.sleep(1)


def parts(v): return tuple(int(x) for x in v.split("."))


def snapshot(folder):
    """Its files and what is in them (the shim is written in again at each
    load, so times change; what it holds mustn't)."""
    return {str(p.relative_to(folder)): hashlib.sha256(p.read_bytes()).hexdigest() for p in folder.rglob("*") if p.is_file()}


def popup_root(id):
    """Bitwarden's popup page in a bench tab: its app root is drawn, and
    its worker hears a message."""
    page = sv.cmd({"do": "ext-page", "id": id, "path": "popup/index.html"})["id"]
    found = None
    for _ in range(40):
        found = sv.cmd({"do": "eval", "id": page, "js": "document.querySelector('app-root') ? document.querySelector('app-root').children.length : -1"}).get("value")
        if isinstance(found, (int, float)) and found > 0: break
        time.sleep(0.5)
    # Its worker: a message from the page reaches a listener there. With no
    # worker running (or one that failed), sendMessage rejects: "Receiving
    # end does not exist" or WebKit's own error.
    js = ("(() => { if (!window.__w) { window.__w = 'waiting'; chrome.runtime.sendMessage({command: 'searchProbe'})"
          ".then(() => window.__w = 'answered', (e) => window.__w = 'error: ' + e.message); } return window.__w; })()")
    worker = None
    for _ in range(40):
        worker = sv.cmd({"do": "eval", "id": page, "js": js}).get("value")
        if worker != "waiting": break
        time.sleep(0.5)
    sv.cmd({"do": "close", "id": page})
    return found, worker


def main():
    t = sv.T()
    sv.APP = probe_copy()
    try:
        sv.setup()
        sv.launch()
        sv.cmd({"do": "ext-answer", "answer": "yes"})
        for i in (BW, UBOL): sv.cmd({"do": "ext-add", "id": i, "yes": True})
        e = loaded([BW, UBOL])
        t.ok("both install from the store", all(i in e and e[i]["loaded"] for i in (BW, UBOL)), e)
        if not all(i in e for i in (BW, UBOL)): return t
        latest, ubol = e[BW]["version"], e[UBOL]["version"]
        t.ok("the store's Bitwarden is 2026.11.0 or later", parts(latest) >= parts("2026.11.0"), latest)
        sv.quit(); time.sleep(1)

        folder = Path(sv.SUPPORT) / "Extensions"
        lst = folder / "installed.json"
        data = json.loads(lst.read_text())
        for item in data:
            if item["id"] == BW: item["version"] = OLD
        lst.write_text(json.dumps(data))
        manifest = folder / BW / "manifest.json"
        m = json.loads(manifest.read_text()); m["version"] = OLD; manifest.write_text(json.dumps(m))
        subprocess.run(["defaults", "delete", sv.SUITE, "extensions.checked"], capture_output=True)
        before = snapshot(folder / UBOL)

        sv.launch()
        sv.cmd({"do": "ext-answer", "answer": "ask"})
        e = loaded([BW, UBOL])
        end = time.time() + 120
        while time.time() < end and exts()[BW]["version"] == OLD: time.sleep(2)
        state = sv.cmd({"do": "ext-check"})  # waits for the launch round, runs none (not due)
        e = loaded([BW, UBOL])
        t.ok("the launch check updates Bitwarden to the store's version", e[BW]["version"] == latest, (e[BW]["version"], latest))
        t.ok("its manifest on disk says so too", json.loads(manifest.read_text())["version"] == latest)
        t.ok("the check is recorded as done, nothing to retry",
             isinstance(state["checkedAgo"], (int, float)) and state["checkedAgo"] < 200 and state["retryIn"] is None and state["failures"] == 0, state)
        # What it says signed out with no desktop app to talk to, as on a
        # fresh install, isn't counted.
        said = [r for r in e[BW]["reported"] if not any(k in r for k in ("connectNative", "NativeMessaging", "logged out"))]
        t.ok("updated Bitwarden is loaded, with no failure or errors",
             e[BW]["loaded"] and not e[BW]["failure"] and not e[BW]["errors"] and not said, e[BW])
        asked = sv.cmd({"do": "ext-answer", "answer": "ask"}).get("asked")
        t.ok("the update asked nothing (no more access)", asked == [], asked)
        drawn, worker = popup_root(BW)
        t.ok("its popup page draws its app", isinstance(drawn, (int, float)) and drawn > 0, drawn)
        t.ok("its worker runs: a message from the page is heard", worker == "answered", worker)
        e = exts()
        t.ok("uBlock Origin Lite, up to date, keeps its version", e[UBOL]["version"] == ubol, (e[UBOL]["version"], ubol))
        t.ok("and its files are untouched", snapshot(folder / UBOL) == before)

        # A failed check: the store unreachable.
        good = state["checkedAgo"]
        refuse = "http://127.0.0.1:9/service/update2/crx"
        s = sv.cmd({"do": "ext-check", "age": 21 * 3600, "base": refuse})
        t.ok("a due check that can't reach the store runs and fails", s["ran"] and s["failures"] == 1, s)
        t.ok("it leaves the last good check as it was", abs(s["checkedAgo"] - (good + 21 * 3600)) < 120, s)
        t.ok("and plans a retry an hour on", 3500 < s["retryIn"] <= 3600, s)
        s = sv.cmd({"do": "ext-check"})
        t.ok("not run again before then", not s["ran"] and s["failures"] == 1, s)
        s = sv.cmd({"do": "ext-check", "age": 1800})
        t.ok("half an hour on, still not", not s["ran"] and s["failures"] == 1, s)
        s = sv.cmd({"do": "ext-check", "age": 1800})
        t.ok("an hour on it runs, fails again, and waits two hours",
             s["ran"] and s["failures"] == 2 and 7100 < s["retryIn"] <= 7200, s)
        s = sv.cmd({"do": "ext-check", "age": 7200, "base": "https://clients2.google.com/service/update2/crx"})
        t.ok("back on the store it works: recorded, retry dropped",
             s["ran"] and s["failures"] == 0 and s["retryIn"] is None and s["checkedAgo"] < 120, s)
        t.ok("versions unchanged by the retries", s["versions"].get(BW) == latest and s["versions"].get(UBOL) == ubol, s["versions"])
        s = sv.cmd({"do": "ext-check"})
        t.ok("and the next isn't due for a day", not s["ran"], s)
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
