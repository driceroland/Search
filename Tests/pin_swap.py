#!/usr/bin/env python3
"""A pin keeps its id, its home and its place in every space when its tab
is swapped between an extension's page and a website, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/pin_swap.py`. It uses the
split suite's harness in a world of its own (see split_view.use()), so it
can run beside that suite. It loads a one-page extension from a folder,
and needs macOS 15.4.
"""
import json
import shutil
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("pin-swap-tests")

t = sv.T()
def pins(): return json.load(open(f"{sv.SUPPORT}/pins.json"))
def pinned():
    st = sv.sp("state"); return [x for x in st["tabs"] if x["id"] in st["pins"]]
folder = Path(tempfile.mkdtemp(prefix="pin-swap-"))
try:
    (folder / "manifest.json").write_text(json.dumps({
        "manifest_version": 3, "name": "Pin Swap", "version": "1.0", "options_page": "options.html"}))
    (folder / "options.html").write_text("<!doctype html><title>options</title><p>options")
    # Pins every space shows need spaces on (Preferences.showsSharedPins).
    sv.setup(spaces=True, **{"pins.shared": True}); sv.launch()
    sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
    base = ext = ""
    for _ in range(100):
        loaded = [e for e in sv.cmd({"do": "extensions"})["extensions"] if e["name"] == "Pin Swap" and e["base"]]
        if loaded: base, ext = loaded[0]["base"], loaded[0]["id"]; break
        time.sleep(0.2)
    t.ok("the extension loads", base, base)
    space = sv.sp("state")["spaceID"]
    # The bench's `go` takes only a website, so the pin starts on the
    # extension's page and the swap is to the web and back.
    home = base.rstrip("/") + "/options.html"
    m = sv.cmd({"do": "ext-page", "id": ext, "path": "options.html"})["id"]; time.sleep(1)
    sv.cmd({"do": "pin", "id": m})
    sv.cmd({"do": "pin", "id": m, "everywhere": True}); sv.sp("save")
    before = pins()["shared"]
    t.ok("pinned at the extension's page, in every space", [p["home"] for p in before] == [home], before)

    def same(when):
        st = sv.sp("state"); tab = [x for x in st["tabs"] if x["id"] in st["pins"]]
        sv.sp("save"); after = pins()
        t.ok(f"{when}: the same pin id and home", [(p["id"], p["home"]) for p in after["shared"]]
             == [(before[0]["id"], home)], after)
        t.ok(f"{when}: still in every space", [x["id"] for x in tab] == st["everywhere"]
             and not after.get(space), (st["everywhere"], after.get(space)))
        return tab

    sv.cmd({"do": "go", "id": m, "url": f"{sv.BASE}/web"}); time.sleep(1.5)
    tab = same("to the web")
    t.ok("to the web: the pin is a new tab at the website", len(tab) == 1 and tab[0]["id"] != m
         and tab[0]["url"] == f"{sv.BASE}/web", tab)
    said = sv.cmd({"do": "pin", "id": tab[0]["id"]})
    t.ok("to the web: the tab's home is the extension's page", said["home"] == home, said)

    # A double-click on the pin goes home, which swaps it back.
    sv.cmd({"do": "pin", "id": tab[0]["id"], "home": True}); time.sleep(1.5)
    tab = same("home")
    t.ok("home: back at the extension's page", len(tab) == 1 and tab[0]["url"] == home, tab)
finally:
    t.done(); sv.finish(); shutil.rmtree(folder, ignore_errors=True)
sys.exit(1 if t.failed else 0)
