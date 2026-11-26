#!/usr/bin/env python3
"""⌘T onto an extension's new tab page puts the keys in the address field
(#1627), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/newtab_extension_focus.py`.
It runs in split_view.py's harness: started hidden in a world of its own,
everything removed afterwards. The extension is a folder made here, with
only a new tab page, allowed to replace new tabs.

Before, the extension's page came up and the keys stayed in it: typing did
nothing until ⌘L. Now the field is up, empty, over the page, as a blank new
tab's is; Escape puts it away and leaves the extension's page.
"""
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("newtab-ext-focus")

t = sv.T()
work = Path(tempfile.mkdtemp(prefix="search-newtab-focus-"))
def make(name):
    folder = work / name.replace(" ", "")
    folder.mkdir()
    (folder / "manifest.json").write_text(json.dumps({
        "manifest_version": 3, "name": name, "version": "1.0",
        "chrome_url_overrides": {"newtab": "newtab.html"},
    }))
    (folder / "newtab.html").write_text(f"<!doctype html><title>{name}</title><p>{name}")
    return str(folder)
def installed(): return sv.cmd({"do": "extensions"})["extensions"]
def add(path, name):
    sv.cmd({"do": "ext-folder", "path": path, "yes": True})
    for _ in range(50):
        found = [x for x in installed() if x["name"] == name and x["loaded"]]
        if found: return found[0]
        time.sleep(0.2)
    raise RuntimeError(f"{name} didn't load")
def cmd_t():
    sv.cmd({"do": "press", "code": 17, "chars": "t", "mods": ["cmd"]}); time.sleep(1.5)
    st = sv.sp("state")
    return st, next(x for x in st["tabs"] if x["id"] == st["activeID"])
def field(): return sv.cmd({"do": "sitesearch", "action": "state"})
def on(tab, ext): return tab["url"].startswith(ext["base"].rstrip("/")) if ext["base"] else ext["name"] in tab.get("title", "")
try:
    sv.setup()
    sv.launch()
    a = sv.page("a")
    sv.sp("select", id=a); time.sleep(0.3)
    sv.cmd({"do": "ext-answer", "answer": "yes"})
    ext = add(make("Tab F"), "Tab F")
    # The first ⌘T asks, and is answered yes.
    st, tab = cmd_t()
    t.ok("first ⌘T: the extension's page", on(tab, ext), tab)
    sv.sp("select", id=a); time.sleep(0.3)
    for n in (2, 3):
        st, tab = cmd_t()
        t.ok(f"⌘T #{n}: a new tab with the extension's page", tab["id"] != a and on(tab, ext), tab)
        f = field()
        t.ok(f"⌘T #{n}: the address field is up, empty", f.get("editing") and not f.get("typed"), f)
        # A key typed now lands in the field, not in the page.
        sv.cmd({"do": "press", "code": 7, "chars": "x", "mods": []}); time.sleep(0.6)
        f = field()
        t.ok(f"⌘T #{n}: a key typed goes into the field", f.get("typed") == "x", f)
        sv.cmd({"do": "press", "code": 53, "chars": "\x1b"}); time.sleep(0.4)
        if field().get("editing"):
            sv.cmd({"do": "press", "code": 53, "chars": "\x1b"}); time.sleep(0.4)
        st = sv.sp("state")
        now = next(x for x in st["tabs"] if x["id"] == st["activeID"])
        t.ok(f"⌘T #{n}: Escape puts it away, the page stays", not field().get("editing") and on(now, ext), (field(), now))
        sv.sp("select", id=a); time.sleep(0.3)
finally:
    t.done(); sv.finish(); subprocess.run(["rm", "-rf", str(work)])
sys.exit(1 if t.failed else 0)
