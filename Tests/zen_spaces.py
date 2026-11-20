"""Zen's spaces, pins, folders and Essentials, brought into a probe world.

Build first (`./build.sh debug`), then, hidden and under the probe lock:
`lockf -t 900 /private/tmp/claude-501/search-probe.lock python3 Tests/zen_spaces.py`.
A made-up Zen profile is written into the world's own Import folder (never
a real browser's), in the file Zen keeps, zen-sessions.jsonlz4, mozLz4 as
Mozilla writes it. The import is asked for through the bench,
the same calls the sheet makes.
"""
import json
import os
import sqlite3
import struct
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("zen-spaces")


def mozlz4(obj):
    """A .jsonlz4: Mozilla's header, the size, one LZ4 block of literals."""
    plain = json.dumps(obj).encode()
    n = len(plain)
    out = b"mozLz40\0" + struct.pack("<I", n)
    if n < 15:
        return out + bytes([n << 4]) + plain
    rest, ext = n - 15, b""
    while rest >= 255:
        ext += b"\xff"; rest -= 255
    return out + b"\xf0" + ext + bytes([rest]) + plain


def tab(url, title, space=None, pinned=False, essential=False, group=None):
    out = {"entries": [{"url": url, "title": title}], "index": 1, "pinned": pinned or essential,
           "zenEssential": essential}
    if space: out["zenWorkspace"] = space
    if group: out["groupId"] = group
    return out


ZEN_TABS = [
    tab("https://mail.example/", "Mail", essential=True),
    tab("https://calendar.example/", "Calendar", essential=True),
    tab("https://docs.example/", "Docs", "{work}", pinned=True),
    tab("https://paper.example/", "Paper", "{work}", pinned=True, group="f1"),
    tab("https://game.example/", "Game", "{play}", pinned=True),
    tab("https://open-one.example/", "Open one", "{work}", group="g1"),
    tab("https://open-two.example/", "Open two", "{work}", group="g1"),
]


def profile(folder):
    os.makedirs(f"{folder}/sessionstore-backups", exist_ok=True)
    db = sqlite3.connect(f"{folder}/places.sqlite")
    db.execute("CREATE TABLE IF NOT EXISTS moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, hidden INTEGER, last_visit_date INTEGER)")
    db.commit(); db.close()


def zen():
    folder = f"{sv.SUPPORT}/Import/zen/Profiles/probe.Default (release)"
    profile(folder)
    sidebar = {
        "spaces": [
            {"uuid": "{work}", "name": "Zen Work", "icon": "💼",
             "theme": {"type": "gradient", "gradientColors": [{"c": [66, 133, 244], "isPrimary": True},
                                                              {"c": [240, 160, 60]}]}},
            {"uuid": "{play}", "name": "Zen Weekend",
             "icon": "chrome://browser/skin/zen-icons/selectable/game-controller.svg",
             "theme": {"type": "gradient", "gradientColors": [{"c": [208, 64, 80], "isPrimary": True}]}},
        ],
        "folders": [{"id": "f1", "name": "Research", "pinned": True, "parentId": None, "workspaceId": "{work}"}],
        "groups": [{"id": "g1", "name": "Reading", "collapsed": False}],
        "tabs": ZEN_TABS,
    }
    Path(f"{folder}/zen-sessions.jsonlz4").write_bytes(mozlz4(sidebar))


def spaces():
    path = f"{sv.SUPPORT}/spaces.json"
    return json.load(open(path)) if os.path.exists(path) else []


def pins():
    path = f"{sv.SUPPORT}/pins.json"
    return json.load(open(path)) if os.path.exists(path) else {}


def main():
    t = sv.T()
    try:
        sv.setup()
        zen()
        sv.launch()

        preview = {b["name"]: b for b in sv.cmd({"do": "import-preview"})["browsers"]}
        t.ok("Zen is found", "Zen" in preview, list(preview))

        out = sv.cmd({"do": "import", "from": "Zen", "what": ["spaces"]})
        arc = out.get("arc") or {}
        t.ok("two spaces made", arc.get("spaces") == 2, arc)
        t.ok("the Essentials are each space's pins", arc.get("pins") == 4, arc)
        t.ok("the three pinned tabs came, asleep", arc.get("tabs") == 3, arc)
        for _ in range(25):
            if any(s["name"] == "Zen Weekend" for s in spaces()): break
            time.sleep(0.2)
        made = {s["name"]: s for s in spaces()}
        work, play = made.get("Zen Work", {}), made.get("Zen Weekend", {})
        t.ok("Work wears its icon, colour and gradient",
             work.get("icon") == "briefcase" and work.get("colour") == 1
             and (work.get("gradient") or {}).get("colours") == ["#4285F4", "#F0A03C"], work)
        t.ok("Weekend wears its picture and colour",
             play.get("icon") == "gamecontroller" and play.get("colour") == 4 and not play.get("gradient"), play)
        homes = sorted(p["home"] for row in pins().values() for p in row)
        t.ok("Mail and Calendar pinned in both spaces",
             homes.count("https://mail.example/") == 2 and homes.count("https://calendar.example/") == 2, homes)

        again = sv.cmd({"do": "import", "from": "Zen", "what": ["spaces"]}).get("arc") or {}
        t.ok("a second import adds nothing", (again.get("spaces"), again.get("pins"), again.get("tabs")) == (0, 0, 0), again)


        # With pinned rows and folders in them on, the pins are rows and
        # Zen's Research folder a folder of rows, as Zen nests it.
        sv.quit()
        sv.setup(**{"pins.list": True, "pins.folders": True})
        zen()
        sv.launch()
        rows = sv.cmd({"do": "import", "from": "Zen", "what": ["spaces"]}).get("arc") or {}
        t.ok("as rows, no tab left over", rows.get("tabs") == 0 and rows.get("pins") == 4 + 3, rows)
        folders_file = f"{sv.SUPPORT}/pin-folders.json"
        for _ in range(25):
            if os.path.exists(folders_file): break
            time.sleep(0.2)
        folders = json.load(open(folders_file)) if os.path.exists(folders_file) else {}
        names = [f.get("name") for row in folders.values() for f in (row if isinstance(row, list) else [])]
        t.ok("Research is a folder of rows", "Research" in names, folders)
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
