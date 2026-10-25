#!/usr/bin/env python3
"""⌘T with the floating field on and an extension's new tab page still to be
asked about, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/newtab_floating_extension.py`.
It runs in split_view.py's test world, with its harness: started hidden,
everything removed afterwards. The extension is a folder made here, with only
a new tab page.

With the field on and a page in front, ⌘T raised the field even when an
extension had asked to replace the new tab page and nobody had answered. The
question comes with a new tab, so it never came, and the page never showed.
"""
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("newtab-floating")

t = sv.T()
work = Path(tempfile.mkdtemp(prefix="search-newtab-floating-"))
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
def field_up(): return sv.cmd({"do": "sitesearch", "action": "state"})["editing"]
# The bench reports what was asked only as it's given an answer, so it is
# given the same one again: any other word goes back to asking for real.
given = ["yes"]
def answer(yes):
    given[0] = "yes" if yes else "no"; sv.cmd({"do": "ext-answer", "answer": given[0]})
def asked(): return sv.cmd({"do": "ext-answer", "answer": given[0]})["asked"]
def on(tab, ext): return tab["url"].startswith(ext["base"].rstrip("/")) if ext["base"] else ext["name"] in tab.get("title", "")
try:
    sv.setup(**{"newtab.floating": True})
    sv.launch()
    a = sv.page("a")
    sv.sp("select", id=a); time.sleep(0.3)

    before = len(sv.sp("state")["tabs"])
    st, tab = cmd_t()
    t.ok("no extension: ⌘T raises the field over the page", tab["id"] == a and field_up(), (tab, field_up()))
    t.ok("no extension: no tab is made", len(st["tabs"]) == before, st["tabs"])
    sv.cmd({"do": "press", "code": 53, "chars": "\x1b"}); time.sleep(0.3)

    answer(True)
    ext = add(make("Tab A"), "Tab A")

    # A private tab's new tab is private too and never asks, so the field
    # comes up there as before.
    shy = sv.cmd({"do": "open", "url": f"{sv.BASE}/p", "private": True})["id"]
    sv.cmd({"do": "wait", "id": shy}); sv.sp("select", id=shy); time.sleep(0.3)
    before = len(sv.sp("state")["tabs"])
    st, tab = cmd_t()
    t.ok("private tab: ⌘T raises the field over the page", tab["id"] == shy and field_up(), (tab, field_up()))
    t.ok("private tab: no tab is made, and nobody is asked", len(st["tabs"]) == before and not asked(), (st["tabs"], asked()))
    sv.cmd({"do": "press", "code": 53, "chars": "\x1b"}); time.sleep(0.3)
    sv.sp("close", id=shy)

    sv.sp("select", id=a); time.sleep(0.3)
    st, tab = cmd_t()
    t.ok("unasked extension: ⌘T opens a tab", tab["id"] != a, tab)
    t.ok("unasked extension: it is asked about", any("Tab A" in q for q in asked()), asked())
    t.ok("unasked extension: yes, and the tab shows its page", on(tab, ext), tab)
    t.ok("unasked extension: no field is up", not field_up())

    # Don't Allow: nothing is left to ask, so the field is back.
    sv.cmd({"do": "ext-remove", "id": ext["id"]}); time.sleep(0.5)
    answer(False)
    b = add(make("Tab B"), "Tab B")
    sv.sp("select", id=a); time.sleep(0.3)
    st, tab = cmd_t()
    t.ok("no to an unasked one: ⌘T opens a tab, and it is asked about", tab["id"] != a and any("Tab B" in q for q in asked()), (tab, asked()))
    t.ok("no to an unasked one: the tab doesn't show its page", not on(tab, b), tab)
    sv.sp("select", id=a); time.sleep(0.3)
    before = len(sv.sp("state")["tabs"])
    st, tab = cmd_t()
    t.ok("no to an unasked one: the next ⌘T raises the field over the page", tab["id"] == a and field_up(), (tab, field_up()))
    t.ok("no to an unasked one: no tab is made", len(st["tabs"]) == before, st["tabs"])
finally:
    t.done(); sv.finish(); subprocess.run(["rm", "-rf", str(work)])
sys.exit(1 if t.failed else 0)
