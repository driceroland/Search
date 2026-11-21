"""History from before 1.0.16 shows in every space it showed in before (#1325).

Build first (`./build.sh`), then `python3 Tests/space_history_seed.py`. A
world as 1.0.15 left it is written before the probe starts: a history.json
with a page in it, and three spaces, the first, Solo (made before the
sign-in choice, so with cookies of its own) and Shared (signed in with the
first). Since 1.0.16 a signed-out space keeps a history of its own (#1166),
and Solo's started empty. Now, at the first launch, the history there was is
copied once into each signed-out space:

- Solo offers the old page, as do the first space and Shared;
- what Solo visits after stays its own: never in the first space's;
- a page forgotten in Solo doesn't come back at the next launch (the copy
  is made once);
- a signed-out space made afterwards starts empty.

Nothing here makes, shows or brings forward a window.
"""
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("sp-history-seed")
FIRST = "00000000-0000-0000-0000-000000000001"
SOLO = "5E5E5E5E-0000-4000-8000-000000000001"
SHARED = "5E5E5E5E-0000-4000-8000-000000000002"
OLD = "https://old.example/wiki"


def history(typed="old"):
    return sv.cmd({"do": "profile", "action": "history", "typed": typed})


def holds(url, typed="old"):
    h = history(typed)
    return url in h["history"], url in h["offers"]


def go(index):
    sv.cmd({"do": "space", "action": "go", "index": index})
    time.sleep(0.8)


def world():
    """As 1.0.15 left it: spaces, and the one history every space shared."""
    sup = Path(sv.SUPPORT)
    sup.mkdir(parents=True, exist_ok=True)
    spaces = [{"id": FIRST, "name": "Personal", "colour": 0},
              {"id": SOLO, "name": "Solo", "colour": 0},
              {"id": SHARED, "name": "Shared", "colour": 0, "sharesSignIns": True}]
    (sup / "spaces.json").write_text(json.dumps(spaces))
    last = datetime.now(timezone.utc).timestamp() - 978307200 - 3600  # an hour ago, from 2001
    (sup / "history.json").write_text(json.dumps([{"url": OLD, "key": OLD, "title": "Old Wiki", "count": 6, "last": last}]))


def main():
    t = sv.T()
    try:
        sv.setup(spaces=True, **{"start.fresh": False})
        world()
        sv.launch()
        time.sleep(1)
        names = [s["name"] for s in sv.cmd({"do": "space"})["spaces"]]
        t.ok("the three spaces", names == ["Personal", "Solo", "Shared"], names)
        go(1)
        t.ok("the first space has the old page", holds(OLD) == (True, True), holds(OLD))
        go(2)
        t.ok("Solo, signed out, has it too: history, and offered", holds(OLD) == (True, True), holds(OLD))
        go(3)
        t.ok("Shared has it", holds(OLD) == (True, True), holds(OLD))

        go(2)
        sv.cmd({"do": "history", "take": "https://solo-only.example/page"})
        time.sleep(0.3)
        t.ok("Solo keeps what it visits", holds("https://solo-only.example/page", "solo")[0], history("solo"))
        go(1)
        t.ok("and the first space never sees it", not holds("https://solo-only.example/page", "solo")[0], history("solo"))

        go(2)
        sv.cmd({"do": "history", "forget": OLD})
        time.sleep(0.3)
        t.ok("the old page forgotten in Solo", not holds(OLD)[0], history())
        sv.quit()
        time.sleep(1)
        sv.launch()
        time.sleep(1.5)
        go(2)
        t.ok("after a relaunch it stays forgotten: the copy is made once", not holds(OLD)[0], history())
        go(1)
        t.ok("and the first space still has it", holds(OLD)[0], history())

        sv.cmd({"do": "space", "action": "new", "name": "Later", "fresh": True})
        time.sleep(1)
        st = sv.cmd({"do": "space"})
        t.ok("a signed-out space made now", st["current"] == "Later" and st["spaces"][-1]["own"], st["current"])
        t.ok("starts empty", history("")["history"] == [], history(""))
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


main()
