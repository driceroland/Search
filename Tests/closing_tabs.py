#!/usr/bin/env python3
"""Settings › Tabs › Close tabs you leave alone, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/closing_tabs.py`. It uses the
split suite's harness: started hidden, no window made or shown, everything
removed afterwards. `close.after` makes the wait an hour, and the bench's
`age` moves a tab's last look back, so nothing here waits for a clock.
"""
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# A world of its own, so another suite on the harness can run at the same
# time: sharing split-tests, each wiped and drove the other's browser.
sv.W = "closing-tests"
sv.SUPPORT = f"{sv.HOME}/Library/Application Support/Search ({sv.W})"
sv.SUITE = f"com.officecommun.search.test.{sv.W}"
sv.SOCK = f"{sv.SUPPORT}/bench.sock"

HOUR = 3600
t = sv.T()


def urls(st): return [x["url"] for x in st["tabs"]]
def by(st, id): return next((x for x in st["tabs"] if x["id"] == id), None)
def at(st, name): return next((x for x in st["tabs"] if x["url"] == f"{sv.BASE}/{name}"), None)
def hour(): subprocess.run(["defaults", "write", sv.SUITE, "close.after", "-float", str(HOUR)])
def on(): subprocess.run(["defaults", "write", sv.SUITE, "tabs.close.after", "-int", "12"])


try:
    # Never, the default: nothing closes however long it is left.
    sv.setup(**{"tabs.groups": True, "splitView": True}); hour(); sv.launch()
    a = sv.page("a"); sv.page("front")
    sv.sp("age", id=a, seconds=2 * HOUR)
    st = sv.sp("tidy")
    t.ok("never: a tab left two hours stays", at(st, "a") is not None, urls(st))
    sv.sp("save")
    left = [e for e in sv.session()["tabs"] if e["url"].endswith("/a")]
    t.ok("file: the tab's last look is written", left and "touched" in left[0], left)
    sv.quit()

    # On: the time ran out while Search was quit, and the tab is gone at launch.
    on(); sv.launch(); st = sv.sp("state")
    t.ok("launch: a tab whose time ran out while quit is closed", at(st, "a") is None, urls(st))
    t.ok("launch: the tab in front stays", at(st, "front") is not None, urls(st))

    # What you keep stays; the rest closes.
    old = sv.page("old"); pinned = sv.page("pinned"); named = sv.page("named")
    grouped = sv.page("grouped"); fresh = sv.page("fresh"); front = sv.page("front2")
    sv.cmd({"do": "pin", "id": pinned}); sv.sp("name", id=named, name="Keep"); sv.sp("group", id=grouped)
    for id in (old, pinned, named, grouped, front):
        sv.sp("age", id=id, seconds=2 * HOUR)
    st = sv.sp("tidy")
    t.ok("on: an ordinary tab left two hours closes", by(st, old) is None, urls(st))
    t.ok("on: a fresh tab stays", by(st, fresh) is not None)
    for id, why in ((pinned, "pinned"), (named, "named"), (grouped, "in a group"), (front, "on screen")):
        tab = by(st, id)
        t.ok(f"on: {why} keeps a tab", tab is not None and tab["staysReason"] == why, tab)
    st = sv.sp("reopen")
    t.ok("⇧⌘T brings the closed tab back", at(st, "old") is not None, urls(st))

    # Something typed and not sent keeps a tab however long it is left. Typed
    # as real keys: Search's form watch is in its own content world, out of
    # eval's reach, and counts only what a person would have typed.
    ty = sv.page("typed")
    sv.ev(ty, "var box = document.createElement('textarea'); document.body.appendChild(box); box.focus(); true")
    sv.cmd({"do": "key", "id": ty, "text": "half a reply"})
    sv.page("away2"); sv.sp("age", id=ty, seconds=2 * HOUR)
    sv.sp("tidy"); time.sleep(1); st = sv.sp("state")
    t.ok("typed: a tab holding something typed stays", by(st, ty) is not None, urls(st))
    # The same box emptied: nothing keeps it now.
    sv.ev(ty, "document.querySelector('textarea').value = ''; true")
    sv.sp("tidy"); time.sleep(1); st = sv.sp("state")
    t.ok("typed: once its box is empty, it closes", by(st, ty) is None, urls(st))

    # A pair goes whole or not at all.
    l = sv.page("left"); r = sv.page("right"); sv.sp("pair", id=r, **{"with": l}, side="right"); sv.page("away")
    sv.sp("age", id=l, seconds=2 * HOUR); st = sv.sp("tidy")
    t.ok("pair: half of it past its time, both stay", by(st, l) is not None and by(st, r) is not None, urls(st))
    sv.sp("age", id=r, seconds=2 * HOUR); st = sv.sp("tidy")
    t.ok("pair: both past their time, both close", by(st, l) is None and by(st, r) is None, urls(st))

    # A private tab stays: nothing could bring it back. Last of these, since
    # a page opened from a private tab is private too.
    sv.sp("private"); time.sleep(0.5)
    shy = next(x["id"] for x in sv.sp("state")["tabs"] if x["shy"])
    sv.page("after"); sv.sp("age", id=shy, seconds=2 * HOUR); st = sv.sp("tidy")
    t.ok("private: stays however long it is left", by(st, shy) is not None and by(st, shy)["staysReason"] == "private", by(st, shy))
    sv.sp("close", id=shy)

    # Let go of a keeping, and the time starts from then.
    st = sv.sp("name", id=named)
    t.ok("unnamed: its time starts again", by(st, named)["idle"] < 60, by(st, named))
    sv.cmd({"do": "pin", "id": pinned, "off": True}); st = sv.sp("tidy")
    tab = by(st, pinned)
    t.ok("unpinned: its time starts again, and it stays", tab is not None and tab["idle"] < 60, tab)

    # The clock goes on across a quit: half an hour left is half an hour after.
    sv.sp("age", id=fresh, seconds=HOUR / 2); sv.sp("save"); sv.quit(); sv.launch()
    tab = at(sv.sp("state"), "fresh")
    t.ok("relaunch: the time away is kept, not started again", tab is not None and tab["idle"] >= HOUR / 2, tab)
    sv.quit()

    # Another space's row closes its own tabs, and its file says so.
    sv.setup(spaces=True); hour(); on(); sv.launch()
    sv.page("home"); first = sv.sp("state")["spaceID"]
    sv.sp("space", spaceAction="new", name="Two"); time.sleep(1)
    y = sv.page("y"); sv.page("z"); two = sv.sp("state")["spaceID"]
    sv.sp("space", spaceAction="go", spaceID=first); time.sleep(0.8)
    sv.sp("age", id=y, seconds=2 * HOUR); sv.sp("tidy")
    saved = [e["url"] for e in sv.session(two)["tabs"]]
    t.ok("parked: the space's file no longer has it", not any(u.endswith("/y") for u in saved), saved)
    sv.sp("space", spaceAction="go", spaceID=two); time.sleep(0.8); st = sv.sp("state")
    t.ok("parked: back in the space, it's gone and the rest is there",
         at(st, "y") is None and at(st, "z") is not None, urls(st))
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
