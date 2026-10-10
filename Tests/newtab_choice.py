#!/usr/bin/env python3
"""Two extensions that each offer a new tab page, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/newtab_choice.py`. It runs in
split_view.py's test world, with its harness: started hidden, everything
removed afterwards. The extensions are two folders made here, each with only
a new tab page.

The second one is asked about even while the first has new tabs, and the
answer decides which page ⌘T opens.
"""
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

t = sv.T()
work = Path(tempfile.mkdtemp(prefix="search-newtab-"))
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
    return next(x for x in st["tabs"] if x["id"] == st["activeID"])
# The bench reports what was asked only as it's given an answer, so it is
# given the same one again: any other word goes back to asking for real.
given = ["yes"]
def answer(yes):
    given[0] = "yes" if yes else "no"; sv.cmd({"do": "ext-answer", "answer": given[0]})
def asked(): return sv.cmd({"do": "ext-answer", "answer": given[0]})["asked"]
def on(tab, ext): return tab["url"].startswith(ext["base"].rstrip("/")) if ext["base"] else ext["name"] in tab.get("title", "")
try:
    sv.setup(); sv.launch()
    a_path, b_path = make("Tab A"), make("Tab B")

    answer(True)
    a = add(a_path, "Tab A")
    tab = cmd_t()
    t.ok("one extension: asked about A", any("Tab A" in q for q in asked()), asked())
    t.ok("one extension: yes, and ⌘T shows A", on(tab, a), tab)

    b = add(b_path, "Tab B")
    before = len(asked())
    tab = cmd_t()
    new = asked()[before:]
    t.ok("A holds new tabs: B is asked all the same", any("Tab B" in q for q in new), new)
    t.ok("yes to B: the tab just opened shows B", on(tab, b), tab)
    tab = cmd_t()
    t.ok("yes to B: the next ⌘T shows B, and nobody is asked", on(tab, b) and len(asked()) == before + 1, (tab, asked()))

    # A no to a newer one leaves the older yes alone.
    sv.cmd({"do": "ext-remove", "id": b["id"]}); time.sleep(0.5)
    sv.cmd({"do": "ext-remove", "id": a["id"]}); time.sleep(0.5)
    answer(True); a = add(a_path, "Tab A"); cmd_t()
    answer(False); b = add(b_path, "Tab B")
    before = len(asked())
    tab = cmd_t()
    t.ok("no to B: B was asked", any("Tab B" in q for q in asked()[before:]), asked()[before:])
    t.ok("no to B: ⌘T still shows A", on(tab, a), tab)
    tab = cmd_t()
    t.ok("no to B: not asked again", len(asked()) == before + 1, asked()[before:])
finally:
    t.done(); sv.finish(); subprocess.run(["rm", "-rf", str(work)])
sys.exit(1 if t.failed else 0)
