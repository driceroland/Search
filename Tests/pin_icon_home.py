#!/usr/bin/env python3
"""A pinned row's icon takes a pin that wandered back to its page, as Arc's
do (idea 1076), in a hidden probe.

Build first (`./build.sh debug`), then `python3 Tests/pin_icon_home.py`.
Pinned rows on, a page pinned as a row and taken somewhere else: a click on
its icon goes back to the pinned page, from the pin you're on and from
another tab; at home, or on a square, the icon has no click of its own and
the row's click is as before. A hidden window's SwiftUI views take no
synthetic clicks, so the click is the bench's `pin … icon`, the same call
the icon's tap makes; where the icon is armed is read from the window.
Nothing is put on a screen.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("pin-icon-home")


def pin(id, **f): return sv.cmd({"do": "pin", "id": id, **f})
def last(url): return (url or "").rsplit("/", 1)[-1]
def url(id): return last(next(x for x in sv.sp("state")["tabs"] if x["id"] == id)["url"])
def editing(): return sv.cmd({"do": "probe"})["tabEditing"] != ""
def wander(id, to):
    sv.cmd({"do": "go", "id": id, "url": f"{sv.BASE}/{to}"}); sv.cmd({"do": "wait", "id": id}); time.sleep(0.6)


def main():
    t = sv.T()
    try:
        sv.setup(sidebar=True, **{"pins.list": True, "pins.home": True, "pins.peek": False})
        sv.launch()
        a = sv.page("a"); b = sv.page("b")
        said = pin(a, listed=True)
        t.ok("pinned as a row at a", said["listed"] and last(said["home"]) == "a", said)
        sv.sp("select", id=a); time.sleep(0.4)
        t.ok("at home: the icon is the row's", pin(a, listed=True)["icon"] is None)

        wander(a, "elsewhere")
        icon = pin(a, listed=True)["icon"]
        t.ok("wandered: the icon is armed, where the row's icon is", icon is not None and icon[0] < 40, icon)

        said = pin(a, icon=True); time.sleep(0.8)
        t.ok("a click on the icon goes back to the pinned page", said["taken"] is True and url(a) == "a", (said, url(a)))
        t.ok("…without opening the address", not editing())
        t.ok("home: not armed any more", pin(a, listed=True)["icon"] is None)

        # At home the icon is the row's: its click does nothing of its own.
        said = pin(a, icon=True); time.sleep(0.5)
        t.ok("home: the icon leaves the click to the row", said["taken"] is False and url(a) == "a", said)

        # From another tab: the pin is picked and goes home.
        wander(a, "elsewhere")
        sv.sp("select", id=b); time.sleep(0.5)
        said = pin(a, icon=True); time.sleep(0.8)
        st = sv.sp("state")
        t.ok("from another tab: the pin is picked", st.get("activeID") == a, (st.get("activeID"), a))
        t.ok("…and back at its page", url(a) == "a", url(a))

        # A pin drawn as a square has no row icon to arm.
        wander(a, "elsewhere")
        pin(a, listed=False); time.sleep(0.5)
        t.ok("a square: no row icon", pin(a, listed=False)["icon"] is None)
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
