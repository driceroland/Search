#!/usr/bin/env python3
"""Settings › Browsing › Return takes the top suggestion (#1556): with it on,
the place on top of the address field's list is picked as you type, so
Return goes to it instead of searching for the words, as in Arc's command
bar. Off, as it ships, nothing is picked and Return searches. The field
keeps what was typed; ↑ lets go of the row, and Return then searches; ↓
still walks the list. An address typed out goes where it says.

Build first (`./build.sh` or `./build.sh debug`), then
`python3 Tests/return_takes_top.py`. It uses the split suite's harness:
started hidden in a world of its own, keys pressed through the app's own
event queue, pages from a server on this Mac.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("return-takes-top")
WORDS = "kettlebell"
PAGE = "notes/kettlebell-club"


def cmd_t():
    sv.cmd({"do": "press", "code": 17, "chars": "t", "mods": ["cmd"], "letgo": True})
    time.sleep(0.8)


def type_in(text):
    sv.cmd({"do": "field", "text": text, "type": True})
    time.sleep(0.6)
    return sv.cmd({"do": "suggest"})


def go():
    s = sv.cmd({"do": "suggest", "action": "go"})
    time.sleep(1.0)
    return s


def world(on):
    """Been to the page once, in a tab of its own (bench tabs leave no
    history), then a new tab to type in."""
    sv.setup(**{"field.top": on})
    sv.launch()
    sv.cmd({"do": "ui", "show": f"{sv.BASE}/{PAGE}"})
    time.sleep(1.5)
    cmd_t()


def main():
    t = sv.T()
    try:
        world(False)
        s = type_in(WORDS)
        top = s["offers"][0] if s["offers"] else ["", "", ""]
        t.ok("off, as it ships: the page is listed on top", top[1] == "visited" and top[2].endswith(PAGE), s["offers"])
        t.ok("and nothing is picked", s["picked"] == -1, s["picked"])
        s = go()
        t.ok("Return searches the words", not s["address"].endswith(PAGE), s["address"])
        sv.quit()

        world(True)
        s = type_in(WORDS)
        t.ok("on: the top place is picked as you type", s["picked"] == 0 and s["offers"][0][2].endswith(PAGE), (s["picked"], s["offers"][:1]))
        t.ok("and the field keeps what was typed", s["completed"] == WORDS, s["completed"])
        s = go()
        t.ok("Return goes to the page", s["address"].endswith(PAGE), s["address"])

        cmd_t()
        type_in(WORDS)
        s = sv.cmd({"do": "suggest", "action": "walk", "step": -1})
        t.ok("↑ lets go of the row", s["picked"] == -1 and s["completed"] == WORDS, (s["picked"], s["completed"]))
        s = go()
        t.ok("then Return searches the words", not s["address"].endswith(PAGE), s["address"])

        cmd_t()
        type_in(WORDS)
        s = sv.cmd({"do": "suggest", "action": "walk", "step": 1})
        t.ok("↓ still walks the list", s["picked"] == 1, s["picked"])
        sv.cmd({"do": "suggest", "action": "esc"})
        time.sleep(0.4)

        cmd_t()
        s = type_in("example.com/kettlebell")
        t.ok("an address typed out is not swapped for a row", s["picked"] == -1, s["picked"])
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


main()
