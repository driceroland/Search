#!/usr/bin/env python3
"""⌘T onto an extension's new tab page that focuses a box of its own as it
loads: the address field stays away and the keys are the page's (#1714), in
a hidden probe.

Build first (`./build.sh`), then `python3 Tests/newtab_extension_ownbox.py`.
It runs in split_view.py's harness: started hidden in a world of its own,
everything removed afterwards. Each case is an extension folder made here,
with only a new tab page, allowed to replace new tabs:

- autofocus: `<input autofocus>`;
- script: the page's script focuses its box 300 ms after loading;
- none: no box focused, so the field comes up over the page, as #1627 made
  it (Tests/newtab_extension_focus.py covers that case in full).
"""
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

PAGES = {
    "autofocus": "<input id=box autofocus>",
    "script": "<input id=box><script src=newtab.js></script>",
    "none": "<input id=box><p>No box focused.",
}
cases = sys.argv[1:] or list(PAGES)
t = sv.T()
work = Path(tempfile.mkdtemp(prefix="search-newtab-ownbox-"))
def make(name, body):
    folder = work / name.replace(" ", "")
    folder.mkdir()
    (folder / "manifest.json").write_text(json.dumps({
        "manifest_version": 3, "name": name, "version": "1.0",
        "chrome_url_overrides": {"newtab": "newtab.html"},
    }))
    (folder / "newtab.html").write_text(f"<!doctype html><title>{name}</title>{body}")
    # An extension page runs no inline script (MV3's policy): the script's own file.
    (folder / "newtab.js").write_text("addEventListener('load', () => setTimeout(() => box.focus(), 300));")
    return str(folder)
def add(path, name):
    sv.cmd({"do": "ext-folder", "path": path, "yes": True})
    for _ in range(50):
        found = [x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == name and x["loaded"]]
        if found: return found[0]
        time.sleep(0.2)
    raise RuntimeError(f"{name} didn't load")
def cmd_t():
    sv.cmd({"do": "press", "code": 17, "chars": "t", "mods": ["cmd"]}); time.sleep(2.0)
    st = sv.sp("state")
    return next(x for x in st["tabs"] if x["id"] == st["activeID"])
def field(): return sv.cmd({"do": "sitesearch", "action": "state"})
def keys(): return sv.cmd({"do": "probe"}).get("pageActivity", {}).get("hasKeys")
def on(tab, ext): return tab["url"].startswith(ext["base"].rstrip("/")) if ext["base"] else ext["name"] in tab.get("title", "")
try:
    for case in cases:
        sv.use(f"newtab-ownbox-{case}")
        sv.setup()
        sv.launch()
        a = sv.page("a")
        sv.sp("select", id=a); time.sleep(0.3)
        sv.cmd({"do": "ext-answer", "answer": "yes"})
        name = f"Box {case}"
        ext = add(make(name, PAGES[case]), name)
        tab = cmd_t()  # the first ⌘T asks, answered yes
        t.ok(f"{case}: first ⌘T opens the extension's page", on(tab, ext), tab)
        sv.sp("select", id=a); time.sleep(0.3)
        for n in (2, 3):
            tab = cmd_t()
            t.ok(f"{case} ⌘T #{n}: a new tab with the extension's page", tab["id"] != a and on(tab, ext), tab)
            focused = sv.ev(tab["id"], "document.activeElement && document.activeElement.id")
            f = field()
            if case == "none":
                t.ok(f"{case} ⌘T #{n}: the field is up over the page", f.get("editing"), (f, focused))
            else:
                t.ok(f"{case} ⌘T #{n}: the page's box is focused", focused == "box", focused)
                t.ok(f"{case} ⌘T #{n}: no field over the page", not f.get("editing"), f)
                t.ok(f"{case} ⌘T #{n}: the page has the keys", keys(), sv.cmd({"do": "probe"}).get("pageActivity"))
                sv.cmd({"do": "press", "code": 7, "chars": "x", "mods": []}); time.sleep(0.6)
                value = sv.ev(tab["id"], "box.value")
                t.ok(f"{case} ⌘T #{n}: a key typed goes into the page's box", value == "x" and not field().get("typed"), (value, field()))
                # ⌘L still brings the field up over it.
                sv.cmd({"do": "press", "code": 37, "chars": "l", "mods": ["cmd"]}); time.sleep(0.6)
                t.ok(f"{case} ⌘T #{n}: ⌘L still raises the field", field().get("editing"), field())
                sv.cmd({"do": "press", "code": 53, "chars": "\x1b"}); time.sleep(0.4)
            sv.sp("select", id=a); time.sleep(0.3)
        sv.finish()
finally:
    t.done(); sv.finish(); subprocess.run(["rm", "-rf", str(work)])
sys.exit(1 if t.failed else 0)
