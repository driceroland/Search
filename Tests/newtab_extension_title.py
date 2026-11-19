#!/usr/bin/env python3
"""An extension's new tab page, with Settings › Tabs › Show the address on
the tab you're on, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/newtab_extension_title.py`.
It runs in split_view.py's test world, with its harness: started hidden,
everything removed afterwards. The extension is a folder made here, with only
a new tab page.

The tab you're on read "Extension page" over an extension's new tab, where
its title says New Tab (#1214). It now shows the title; another page of the
same extension still says it isn't a website.
"""
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("newtab-title")

t = sv.T()
work = Path(tempfile.mkdtemp(prefix="search-newtab-title-"))
folder = work / "NewTab"
folder.mkdir()
(folder / "manifest.json").write_text(json.dumps({
    "manifest_version": 3, "name": "Tab Title", "version": "1.0",
    "chrome_url_overrides": {"newtab": "newtab.html"},
}))
(folder / "newtab.html").write_text("<!doctype html><title>New Tab</title><p>new tab")
(folder / "other.html").write_text("<!doctype html><title>Other</title><p>other")
def installed(): return sv.cmd({"do": "extensions"})["extensions"]
def tab(id): return next(x for x in sv.cmd({"do": "tabs"})["tabs"] if x["id"] == id)
try:
    sv.setup()
    sv.launch()
    a = sv.page("a")
    sv.sp("select", id=a); time.sleep(0.3)
    sv.cmd({"do": "ui", "address": True}); time.sleep(0.3)
    sv.cmd({"do": "ext-answer", "answer": "yes"})
    sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
    ext = None
    for _ in range(50):
        found = [x for x in installed() if x["name"] == "Tab Title" and x["loaded"]]
        if found: ext = found[0]; break
        time.sleep(0.2)
    t.ok("the extension loads", ext is not None, installed())

    t.ok("a website's tab says its site", tab(a)["atRestShown"], tab(a))

    sv.cmd({"do": "press", "code": 17, "chars": "t", "mods": ["cmd"]}); time.sleep(2)
    st = sv.sp("state"); new = tab(st["activeID"])
    t.ok("⌘T shows the extension's page", new["id"] != a and new["view"].endswith("/newtab.html"), new)
    t.ok("its tab doesn't say \"Extension page\"", not new["atRestShown"], new)

    sv.cmd({"do": "eval", "id": new["id"], "js": "location.href = 'other.html'; 1"}); time.sleep(1.5)
    again = tab(new["id"])
    t.ok("another page of the extension still says so", again["view"].endswith("/other.html") and again["atRestShown"]
         and again["atRest"] == "Extension page", again)
finally:
    t.done(); sv.finish(); subprocess.run(["rm", "-rf", str(work)])
sys.exit(1 if t.failed else 0)
