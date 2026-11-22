#!/usr/bin/env python3
"""A pin's name at rest (idea 937): a pin you named shows that name when it
is put down or not yet loaded, browsed in, closed with ⌘W and after a
restart; the page's title only while it shows a page.

Two kinds of name. One given in Search (Rename) is the tab's own and stays
through everything. One brought in from Arc or Zen, where a renamed pin's
name is the title it is kept with, used to be written over by whatever
page the pin was last on, and ⌘W with Pins go back home left the host:
the row then said 127.0.0.1 instead of the name.

Build first (`./build.sh`), then `python3 Tests/pin_names.py`. It uses the
split suite's harness: started hidden, in a world of its own, nothing made
or shown on screen, everything removed afterwards.
"""
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("pin-names")

t = sv.T()
def tab(st, id): return next(x for x in st["tabs"] if x["id"] == id)
def label(id): return tab(sv.sp("state"), id)["label"]
def pin(id, **f): return sv.cmd({"do": "pin", "id": id, **f})
def wander(id, to):
    sv.cmd({"do": "go", "id": id, "url": f"{sv.BASE}/{to}"}); sv.cmd({"do": "wait", "id": id}); time.sleep(0.4)
def pins_file(): return json.load(open(f"{sv.SUPPORT}/pins.json"))
def relaunch(home):
    sv.sp("save"); sv.quit()
    subprocess.run(["defaults", "write", sv.SUITE, "pins.home", "-bool", "true" if home else "false"])
    sv.launch(); time.sleep(0.6)
    st = sv.sp("state")
    return st, st["pins"]

try:
    for home in (True, False):
        mode = "home on" if home else "home off"
        sv.setup(sidebar=True, **{"pins.home": home, "pins.peek": False}); sv.launch()
        a = sv.page("mail"); b = sv.page("news"); c = sv.page("docs")
        pin(a, listed=True); pin(b, listed=True); pin(c, listed=True)

        # Named in Search.
        sv.sp("name", id=a, name="Alpha")
        # Renamed in Arc and brought over: the name is the title it is kept
        # with, as the import writes it.
        sv.sp("save"); sv.quit()
        defs = pins_file()
        for row in defs.values():
            for d in row:
                if d["home"].endswith("/news"):
                    d["title"] = "Bee Name"; d["titled"] = True; d.pop("name", None)
                if d["home"].endswith("/docs"):
                    # A pin written before: its title whatever it last showed.
                    d["title"] = "somewhere"; d.pop("titled", None)
        json.dump(defs, open(f"{sv.SUPPORT}/pins.json", "w"))
        sv.launch(); time.sleep(0.6)
        st = sv.sp("state"); a, b, c = st["pins"]
        sv.sp("close", id=b); time.sleep(0.3)
        t.ok(f"{mode}: Rename's name at rest", label(a) == "Alpha", label(a))
        t.ok(f"{mode}: the brought-in name at rest", label(b) == "Bee Name", label(b))

        for id, named in ((a, "Alpha"), (b, "Bee Name")):
            sv.sp("select", id=id); sv.cmd({"do": "wait", "id": id}); time.sleep(0.4)
            if named == "Bee Name":
                t.ok(f"{mode}: the page's title on its pinned page", label(id) == "news", label(id))
            wander(id, "elsewhere")
            browsing = label(id)
            if named == "Alpha":
                t.ok(f"{mode}: Rename's name while browsing", browsing == "Alpha", browsing)
            else:
                t.ok(f"{mode}: the page's title while browsing", browsing == "elsewhere", browsing)
            sv.sp("save")
            sv.sp("close", id=id); time.sleep(0.3)
            # Put down where it wandered (Pins go back home off), it wakes
            # there, and says so.
            want = named if (home or named == "Alpha") else "elsewhere"
            t.ok(f"{mode}: {named} after ⌘W", label(id) == want, label(id))

        # The pin written before: woken on its page, it takes that title once.
        sv.sp("select", id=c); sv.cmd({"do": "wait", "id": c}); time.sleep(0.4)
        sv.sp("save"); wander(c, "away"); sv.sp("save")
        if not home: pin(c, home=True); sv.cmd({"do": "wait", "id": c}); time.sleep(0.4)
        sv.sp("close", id=c); time.sleep(0.3)
        t.ok(f"{mode}: a pin from before says its page's title, not the host", label(c) == "docs", label(c))

        if not home:
            pin(b, home=True); sv.cmd({"do": "wait", "id": b}); time.sleep(0.4)
            sv.sp("close", id=b); time.sleep(0.3)
            t.ok(f"{mode}: put down on its pinned page, the name", label(b) == "Bee Name", label(b))

        st, (a, b, c) = relaunch(home)
        t.ok(f"{mode}: Rename's name after a restart", label(a) == "Alpha", label(a))
        t.ok(f"{mode}: the brought-in name after a restart", label(b) == "Bee Name", label(b))
        t.ok(f"{mode}: the pin from before after a restart", label(c) == "docs", label(c))
        titles = {d["home"].rsplit("/", 1)[-1]: d["title"] for row in pins_file().values() for d in row}
        t.ok(f"{mode}: pins.json keeps the pins' own titles", titles.get("news") == "Bee Name" and titles.get("docs") == "docs", titles)
        sv.finish()
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
