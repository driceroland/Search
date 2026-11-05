#!/usr/bin/env python3
"""The address field's keys, pressed again and mixed: the key that raised the
field puts it away, ⌘K walks only while ⌘ is held, and what was typed
survives a change of key and a ⌘T put away.

Build first (`./build.sh` or `./build.sh debug`), then
`python3 Tests/field_keys.py`. It uses the split suite's harness: started
hidden in a world of its own, keys pressed through the app's own event queue.

Reported as: ⌘T again left the field up with what was typed cleared, ⌘L
again put the page's address back over an edit, ⌘K, let go, ⌘K switched to
the second tab in the list, and ⌘T, ⌘K and ⌘L each cleared what the other
had been given.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("field-keys")
KEYS = {"t": 17, "l": 37, "k": 40}


def press(key, letgo=True):
    sv.cmd({"do": "press", "code": KEYS[key], "chars": key, "mods": ["cmd"], "letgo": letgo})
    time.sleep(0.6)


def bare(code, chars):
    sv.cmd({"do": "press", "code": code, "chars": chars, "mods": []})
    time.sleep(0.8)


def put(text):
    sv.cmd({"do": "field", "text": text})
    time.sleep(0.4)


def state():
    s = sv.cmd({"do": "suggest"})
    return {"up": s["editing"], "typed": s["typed"], "front": s["address"],
            "tabs": [t.get("url", "") for t in sv.cmd({"do": "tabs"})["tabs"]]}


def main():
    t = sv.T()
    try:
        sv.setup(**{"newtab.floating": True})
        sv.launch()
        a, b, c = sv.page("alpha"), sv.page("bravo"), sv.page("charlie")
        sv.sp("select", id=b); time.sleep(0.5)
        start = state()

        press("t"); put("half typed")
        press("t")
        s = state()
        t.ok("⌘T again puts the field away, every tab where it was",
             not s["up"] and s["tabs"] == start["tabs"] and s["front"] == start["front"], s)
        press("t")
        s = state()
        t.ok("the next ⌘T brings back what was typed", s["up"] and s["typed"] == "half typed", s)
        bare(53, "\x1b")
        press("t")
        t.ok("and so after Escape", state()["typed"] == "half typed", state())

        press("k")
        s = state()
        t.ok("⌘T, then ⌘K: the words stay, now finding open tabs", s["up"] and s["typed"] == "half typed", s)
        press("l")
        s = state()
        t.ok("then ⌘L: still the words, for this page now", s["up"] and s["typed"] == "half typed", s)
        press("l")
        t.ok("⌘L again puts it away", not state()["up"], state())

        press("l")
        s = state()
        t.ok("⌘L brings the page's address when nothing was typed", s["typed"].endswith("/bravo"), s)
        press("t")
        t.ok("⌘L, then ⌘T: the page's own address isn't carried into a new tab", state()["typed"] == "", state())
        bare(53, "\x1b")

        press("t"); put(sv.BASE.replace("http://", "") + "/delta"); bare(36, "\r")
        time.sleep(0.8)
        sv.sp("select", id=b); time.sleep(0.5)
        press("t")
        t.ok("after Return opened something, ⌘T starts empty", state()["typed"] == "", state())
        bare(53, "\x1b")

        before = state()["front"]
        press("k"); press("k")
        s = state()
        t.ok("⌘K, let go, ⌘K: put away, still on the same page", not s["up"] and s["front"] == before, s)

        press("k", letgo=False); press("k", letgo=True)
        time.sleep(0.6)
        s = state()
        t.ok("⌘K held, ⌘K again, ⌘ let go: a step down the list, as before",
             not s["up"] and s["front"] != before, s)
    finally:
        t.done()
        sv.finish()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
