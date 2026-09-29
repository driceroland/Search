#!/usr/bin/env python3
"""Settings › Tabs › Pins in every space, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/shared_pins.py`. It uses the
split suite's harness: started hidden, no window made or shown, everything
removed afterwards. The order in the column is checked by hand.
"""
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# A world of its own, its socket included: launch() waits on SOCK.
sv.W = "shared-pins"
sv.SUPPORT = f"{sv.HOME}/Library/Application Support/Search ({sv.W})"
sv.SUITE = f"com.officecommun.search.test.{sv.W}"
sv.SOCK = f"{sv.SUPPORT}/bench.sock"

t = sv.T()
def state(): return sv.sp("state")
def names(st, ids): m = {x["id"]: x["url"].rsplit("/", 1)[-1] for x in st["tabs"]}; return [m[i] for i in ids]
def pins(st): return names(st, st["pins"])
def shared(st): return names(st, st["everywhere"])
def tab_of(st, name): return next(x["id"] for x in st["tabs"] if x["url"].endswith("/" + name))
def front(st): return next(x for x in st["tabs"] if x["id"] == st["activeID"])
def go(n): sv.cmd({"do": "space", "action": "go", "index": n}); time.sleep(0.8)
def pin(id, **f): return sv.cmd({"do": "pin", "id": id, **f})
def ui(**f): sv.cmd({"do": "ui", **f}); time.sleep(0.8)

try:
    # The switch off, as for everyone who never turns it on.
    sv.setup(spaces=True); sv.launch()
    a = sv.page("a"); pin(a)
    t.ok("switch off: Keep in Every Space does nothing", pin(a, everywhere=True)["everywhere"] is False)
    sv.cmd({"do": "space", "action": "new", "name": "Two"}); time.sleep(1)
    t.ok("switch off: another space has none of this space's pins", pins(state()) == [], pins(state()))
    sv.sp("save"); sv.quit()
    t.ok("switch off: pins.json has no shared key", "shared" not in json.load(open(f"{sv.SUPPORT}/pins.json")))

    # On.
    sv.setup(spaces=True, **{"pins.shared": True}); sv.launch()
    mail = sv.page("mail"); notes = sv.page("notes")
    # Notes pinned first, so sharing mail has to move it ahead.
    pin(notes); pin(mail)
    pin(mail, everywhere=True); time.sleep(0.5)
    st = state(); first = st["spaceID"]; first_store = st["pinStores"][tab_of(st, "mail")]
    t.ok("kept: first in this space, the space's own after", pins(st) == ["mail", "notes"] and shared(st) == ["mail"], (pins(st), shared(st)))

    sv.cmd({"do": "space", "action": "new", "name": "Work", "fresh": True}); time.sleep(1)
    st = state()
    t.ok("kept: a new space shows it", pins(st) == ["mail"] and shared(st) == ["mail"], (pins(st), shared(st)))
    work_mail = tab_of(st, "mail")
    t.ok("kept: asleep there until gone to", next(x for x in st["tabs"] if x["id"] == work_mail)["asleep"])
    t.ok("kept: a space started afresh signs in on its own", st["pinStores"][work_mail] != first_store, (st["pinStores"], first_store))

    # Only in This Space, while the pin is the tab in front in the first space.
    go(1); sv.cmd({"do": "select", "id": tab_of(state(), "mail")}); go(2)
    pin(tab_of(state(), "mail"), everywhere=False); time.sleep(0.5)
    st = state()
    t.ok("only here: kept by this space", pins(st) == ["mail"] and shared(st) == [], (pins(st), shared(st)))
    go(1); st = state()
    t.ok("only here: gone from the other space", pins(st) == ["notes"], pins(st))
    t.ok("only here: the other space lands on a tab", st["activeID"] in [x["id"] for x in st["tabs"]] and front(st)["url"].rsplit("/", 1)[-1] != "mail", front(st))

    # Unpin takes a shared pin out of every space.
    go(2); pin(tab_of(state(), "mail"), everywhere=True); time.sleep(0.5)
    go(1); t.ok("shared again: back in the first space", pins(state()) == ["mail", "notes"], pins(state()))
    pin(tab_of(state(), "mail"), off=True); time.sleep(0.5)
    go(2); t.ok("unpinned: gone from every space", pins(state()) == [], pins(state()))

    # Switch off hides, on brings back, a restart keeps it.
    go(1); cal = sv.page("cal"); pin(cal); pin(cal, everywhere=True); time.sleep(0.5)
    ui(sharedpins=False)
    t.ok("switch off: gone from the row", pins(state()) == ["notes"], pins(state()))
    go(2); t.ok("switch off: gone from the other space", pins(state()) == [], pins(state()))
    ui(sharedpins=True)
    t.ok("switch on: back", pins(state()) == ["cal"], pins(state()))
    sv.sp("save"); sv.quit(); sv.launch()
    st = state(); t.ok("restart: still shared", shared(st) == ["cal"], (pins(st), shared(st)))

    # Spaces off and on.
    ui(spaces=False); t.ok("spaces off: shared pins leave", pins(state()) == ["notes"], pins(state()))
    ui(spaces=True); t.ok("spaces on: back", pins(state()) == ["cal", "notes"], pins(state()))

    # The space you're in deleted: the others keep the shared pins.
    go(2); sv.cmd({"do": "space", "action": "delete"}); time.sleep(1)
    st = state(); t.ok("space deleted: the first space keeps them", pins(st) == ["cal", "notes"] and st["spaceID"] == first, (pins(st), st["spaceID"]))

    # Show as Row on the space's own square: it goes below the shared rows,
    # where pins.json and every other space have it.
    sr = sv.page("sr"); pin(sr, listed=True); pin(sr, everywhere=True); time.sleep(0.5)
    t.ok("blocks: a shared row sits after the squares", pins(state()) == ["cal", "notes", "sr"], pins(state()))
    pin(tab_of(state(), "notes"), listed=True); time.sleep(0.5)
    t.ok("blocks: an own pin made a row goes after the shared rows", pins(state()) == ["cal", "sr", "notes"], pins(state()))

    # A pin moved to a space not on screen survives a change to the shared pins.
    sv.cmd({"do": "space", "action": "new", "name": "Three"}); time.sleep(1); go(1)
    x = sv.page("x"); pin(x); time.sleep(0.5)
    sv.cmd({"do": "tospace", "id": x, "index": 2}); time.sleep(0.8)
    y = sv.page("y"); pin(y); pin(y, everywhere=True); time.sleep(0.8)
    go(2); st = state()
    t.ok("moved: the pin is there in the space it went to", "x" in pins(st), pins(st))
    go(1)

    # Kept in every space from one window: another window showing the space
    # keeps its own tab for the pin, page and all.
    sv.cmd({"do": "windows", "action": "new"}); time.sleep(1.5)
    other = sv.sp("state", window=2)
    kept = tab_of(other, "x") if "x" in pins(other) else None
    z = sv.page("z"); pin(z); time.sleep(0.8)
    other = sv.sp("state", window=2); theirs = tab_of(other, "z")
    sv.cmd({"do": "go", "id": theirs, "url": f"{sv.BASE}/z-thread", "window": 2}); time.sleep(1)
    pin(z, everywhere=True); time.sleep(0.8)
    other = sv.sp("state", window=2)
    same = [x for x in other["tabs"] if x["id"] == theirs]
    t.ok("windows: the other window keeps its tab for the pin", bool(same), [x["url"] for x in other["tabs"]])
    t.ok("windows: and its page", bool(same) and same[0]["url"].endswith("/z-thread"), same)
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
