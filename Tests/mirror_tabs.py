#!/usr/bin/env python3
"""Same tabs in every window (Settings › Tabs › Windows, Twins.swift), in a
hidden probe with two windows.

Build first (`./build.sh debug`), then `python3 Tests/mirror_tabs.py`. It
uses the split suite's harness: started hidden, in a world of its own,
driven through ./bench's socket, everything removed afterwards. Nothing here
shows or brings forward a window.

- off, each window's open tabs are its own, as before;
- on, every window lists them all: opened, named, grouped and closed in one
  window, so in the other;
- the same tab picked in both windows has its page in both, and back in the
  first it is still there;
- closing a window leaves its tabs in the other, and a relaunch brings both
  windows back with the same tabs, still twinned.
"""
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("mirror-tabs")


def windows():
    return sv.cmd({"do": "windows"})["windows"]


def urls(n):
    return [u for u in windows()[n - 1]["tabs"] if u]


def state(n):
    return sv.cmd({"do": "split", "action": "state", "window": n})


def tab(n, path):
    want = f"{sv.BASE}/{path}"
    return next((x for x in state(n)["tabs"] if x["url"] == want), None)


def tid(n, path):
    found = tab(n, path)
    return found and found["id"]


def title(n, id):
    return sv.cmd({"do": "eval", "id": id, "js": "document.title", "window": n}).get("value")


def settled(cond, within=6):
    end = time.time() + within
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.3)
    return cond()


def u(path):
    return f"{sv.BASE}/{path}"


def main():
    t = sv.T()
    try:
        sv.setup(); sv.launch()
        sv.page("a")
        sv.cmd({"do": "windows", "action": "new"}); time.sleep(1.5)
        sv.sp("open", url=u("b"), window=2); time.sleep(1)
        t.ok("two windows", len(windows()) == 2, windows())
        t.ok("off: window 1 doesn't get window 2's tab", u("b") not in urls(1), urls(1))
        t.ok("off: window 2 doesn't get window 1's tab", u("a") not in urls(2), urls(2))

        v = sv.cmd({"do": "settings", "set": "tabs.mirror", "value": True})["values"]
        t.ok("switched on", v.get("tabs.mirror") is True, v.get("tabs.mirror"))
        t.ok("on: window 1 lists window 2's tab", settled(lambda: u("b") in urls(1)), urls(1))
        t.ok("on: window 2 lists window 1's tab", settled(lambda: u("a") in urls(2)), urls(2))
        t.ok("the same order in both", urls(1) == urls(2), (urls(1), urls(2)))

        sv.page("c")
        t.ok("opened in 1, listed in 2", settled(lambda: u("c") in urls(2)), urls(2))
        c2 = tab(2, "c")
        t.ok("…asleep there until looked at", c2 and c2["asleep"] and not c2["built"], c2)
        t.ok("…and window 2 stays where it was", state(2)["activeID"] == tid(2, "b"), state(2)["activeID"])

        sv.sp("name", id=tid(2, "c"), name="Kept", window=2)
        def named():
            sv.sp("save")
            return any(e.get("name") == "Kept" and e["url"] == u("c") for e in sv.session()["tabs"])
        t.ok("named in 2, named in 1", settled(named), sv.session()["tabs"])

        sv.sp("group", id=tid(1, "a"))
        t.ok("grouped in 1, a group in 2", settled(lambda: len(state(2)["groups"]) == 1), state(2)["groups"])
        def grouped():
            st = state(2)
            ids = {x["url"]: g for x, g in zip(st["tabs"], st["groupIDs"])}
            return ids.get(u("a")) == st["groups"][0]["id"] if st["groups"] else False
        t.ok("…holding the same tab", settled(grouped), state(2))

        sv.sp("close", id=tid(2, "c"), window=2)
        t.ok("closed in 2, closed in 1", settled(lambda: u("c") not in urls(1)), urls(1))

        # The same tab picked in both windows: each shows the page.
        sv.sp("select", id=tid(1, "b"))
        sv.sp("select", id=tid(2, "b"), window=2)
        t.ok("picked in both: on screen in 1", settled(lambda: (tab(1, "b") or {}).get("built") and title(1, tid(1, "b")) == "b"),
             tab(1, "b"))
        t.ok("picked in both: on screen in 2", settled(lambda: (tab(2, "b") or {}).get("built") and title(2, tid(2, "b")) == "b"),
             tab(2, "b"))
        sv.sp("select", id=tid(1, "a"))
        sv.sp("select", id=tid(1, "b"))
        t.ok("back in 1, its page is still there", settled(lambda: title(1, tid(1, "b")) == "b" and not tab(1, "b")["blank"]),
             tab(1, "b"))
        t.ok("…and still in 2", title(2, tid(2, "b")) == "b", tab(2, "b"))
        t.ok("each window its own view", tab(1, "b")["web"] != tab(2, "b")["web"], (tab(1, "b"), tab(2, "b")))

        # Taken to another page in 1 while 2 looks elsewhere: 2 follows.
        sv.sp("select", id=tid(2, "a"), window=2)
        sv.cmd({"do": "go", "id": tid(1, "b"), "url": u("d")})
        t.ok("taken elsewhere in 1, 2's tab follows", settled(lambda: u("d") in urls(2) and u("b") not in urls(2)), urls(2))
        sv.sp("select", id=tid(2, "d"), window=2)
        t.ok("…and picked in 2 shows that page", settled(lambda: title(2, tid(2, "d")) == "d"), tab(2, "d"))
        t.ok("…with 1's history behind it", settled(lambda: (tab(2, "d") or {}).get("canBack")), tab(2, "d"))

        # A private tab stays in its window.
        shy = [x["id"] for x in sv.sp("private", window=2)["tabs"] if x["shy"]]
        sv.cmd({"do": "go", "id": shy[-1], "url": u("p"), "window": 2}) if shy else None
        time.sleep(1.5)
        t.ok("a private tab stays in its window", shy and u("p") in urls(2) and u("p") not in urls(1), (urls(1), urls(2)))
        if shy: sv.sp("close", id=shy[-1], window=2)

        # Window 2 closed: window 1 keeps every tab.
        before = urls(1)
        sv.cmd({"do": "windows", "action": "close", "n": 2}); time.sleep(2)
        t.ok("window 2 closed: one left", len(windows()) == 1, windows())
        t.ok("…with every tab", urls(1) == before, (before, urls(1)))

        # A new window lists them too; a relaunch brings both back, twinned.
        sv.cmd({"do": "windows", "action": "new"}); time.sleep(1.5)
        t.ok("a new window lists them", settled(lambda: set(urls(2)) == set(before)), urls(2))
        sv.sp("save"); sv.sp("save", window=2)
        sv.quit(); sv.launch(); time.sleep(2)
        t.ok("relaunch: two windows", settled(lambda: len(windows()) == 2), windows())
        t.ok("relaunch: the same tabs in both", settled(lambda: set(urls(1)) == set(before) and set(urls(2)) == set(before)),
             (urls(1), urls(2)))
        sv.sp("close", id=tid(1, "a"))
        t.ok("relaunch: still twinned, closed in 1 closes in 2", settled(lambda: u("a") not in urls(2)), urls(2))

        # Off again: each window's own from here on.
        sv.cmd({"do": "settings", "set": "tabs.mirror", "value": False}); time.sleep(0.6)
        sv.sp("open", url=u("e"), window=2); time.sleep(1.5)
        t.ok("off again: window 1 doesn't get it", u("e") not in urls(1), urls(1))
        t.ok("off again: nothing written of it", all("twinID" not in json.dumps(e) for e in (sv.sp("save") and sv.session())["tabs"]))
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
