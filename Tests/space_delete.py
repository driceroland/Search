"""Spaces brought in from Arc can be deleted, and stay deleted.

Build first (`./build.sh`), then `python3 Tests/space_delete.py`. The same
made-up Arc profile as spaces_quit_keep.py (two spaces, each a loose page
and a folder) is imported into a hidden probe; each imported space is then
deleted the way its menu's Delete does (Browser.deleteSpace, through the
bench), and the probe quits and starts again. The spaces, their files and
their tabs must be gone, before and after the relaunch; the first space,
which holds the session there was before spaces, is the one that stays.

Nothing here makes, shows or brings forward a window. The menu itself (the
space's icon, Delete “…”) is checked by hand.
"""
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402
import spaces_quit_keep as keep  # noqa: E402

sv.use("hub-sp-delete")


def names():
    return [s["name"] for s in json.load(open(f"{sv.SUPPORT}/spaces.json"))]


def files():
    return sorted(p.name for p in Path(sv.SUPPORT).glob("session-*.json"))


def main():
    t = sv.T()
    try:
        sv.setup(**{"tabs.groups": True})
        keep.arc()
        sv.launch()
        out = sv.cmd({"do": "import", "from": "Arc", "what": ["spaces"]}).get("arc") or {}
        t.ok("Arc's two spaces came in", out.get("spaces") == 2, out)
        time.sleep(1.5)
        ids = keep.ids()
        t.ok("each has its file", len(files()) == 2, files())

        # The space on screen, deleted: back to the first, the space gone.
        keep.go("Work")
        sv.cmd({"do": "space", "action": "delete"})
        time.sleep(1)
        st = sv.cmd({"do": "space"})
        t.ok("Work deleted from its own screen: back on the first space", st["current"] == "Personal", st["current"])
        t.ok("Work is out of the list", names() == ["Personal", "Study"], names())
        t.ok("and its file is gone", f"session-{ids['Work']}.json" not in files(), files())
        t.ok("and its row isn't kept in memory", all(ids["Work"] not in p for p in st["parked"]), st["parked"])

        keep.go("Study")
        sv.cmd({"do": "space", "action": "delete"})
        time.sleep(1)
        t.ok("Study deleted too: only the first space is left", names() == ["Personal"], names())
        t.ok("no space file left", files() == [], files())

        # The first space can't be: it is where the session was before spaces.
        sv.cmd({"do": "space", "action": "delete"})
        time.sleep(0.5)
        t.ok("the first space stays", names() == ["Personal"], names())

        sv.quit()
        time.sleep(1)
        sv.launch()
        time.sleep(1)
        st = sv.cmd({"do": "space"})
        t.ok("after ⌘Q and a relaunch, the deleted spaces stay deleted",
             [s["name"] for s in st["spaces"]] == ["Personal"] and names() == ["Personal"], st["spaces"])
        t.ok("and no file came back", files() == [], files())
        titles = [x["title"] for x in sv.cmd({"do": "tabs"})["tabs"]]
        t.ok("none of their pages turned up in the first space",
             not any(x in titles for x in ("IANA", "RFC", "WHATWG", "MDN", "Ex", "W3")), titles)
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
