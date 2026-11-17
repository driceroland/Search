#!/usr/bin/env python3
"""Menu commands and Settings pages in the address field, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/command_bar.py`. Off unless
Address bar commands is on; then words typed find the menu's commands and
Settings' pages, under everything else, with their keys.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("command-bar")
t = sv.T()


def typed(text):
    sv.cmd({"do": "field", "text": text, "type": True})
    time.sleep(0.3)
    s = sv.cmd({"do": "suggest"})
    sv.cmd({"do": "suggest", "action": "esc"})
    time.sleep(0.2)
    return s.get("offers", [])


def commands(offers): return [o for o in offers if o[1] == "command"]
def text(o): return " ".join(str(x) for x in o)


try:
    sv.setup(commandbar=False); sv.launch()
    sv.page("a")
    t.ok("off: no command for 'hide el'", not any("Hide Elements" in text(o) for o in typed("hide el")))
    sv.quit()

    sv.setup(commandbar=True); sv.launch()
    sv.page("a")
    offers = typed("hide el")
    found = [o for o in commands(offers) if "Hide Elements" in text(o)]
    t.ok("on: 'hide el' offers Hide Elements…", found, offers)
    t.ok("on: the command row comes last", offers and found and offers[-1] == found[-1], offers)
    t.ok("on: Return stays a search (first row isn't a command)", offers and offers[0][1] != "command", offers)
    offers = typed("privacy")
    t.ok("on: 'privacy' offers Privacy Settings", any("Privacy" in text(o) for o in commands(offers)), offers)
    offers = typed("split cur")
    t.ok("on: 'split cur' offers Split Current Page", any("Split Current Page" in text(o) for o in commands(offers)), offers)
    offers = typed("reload.com")
    t.ok("on: an address offers no command", not commands(offers), offers)
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
