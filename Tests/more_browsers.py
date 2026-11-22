"""Browsers added for coming from anywhere, found and brought into a probe
world: Naver Whale (Chromium), Orion (WebKit) and the Gecko forks.

Build first (`./build.sh debug`), then, hidden and under the probe lock:
`lockf -t 900 /private/tmp/claude-501/search-probe.lock python3 Tests/more_browsers.py`.
Made-up profiles are written into the world's own Import folder, never a
real browser's.
"""
import json
import os
import plistlib
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("more-browsers")


def whale():
    folder = f"{sv.SUPPORT}/Import/Naver/Whale/Default"
    os.makedirs(folder, exist_ok=True)
    bar = {"type": "folder", "name": "Bar", "children": [
        {"type": "url", "name": "Whale page", "url": "https://whale-page.example/"},
        {"type": "folder", "name": "News", "children": [
            {"type": "url", "name": "Paper", "url": "https://paper.example/"}]}]}
    Path(f"{folder}/Bookmarks").write_text(json.dumps({"roots": {"bookmark_bar": bar}}))


def orion():
    folder = f"{sv.SUPPORT}/Import/Orion/Defaults"
    os.makedirs(folder, exist_ok=True)
    items = {
        "fav": {"id": "fav", "type": "folder", "title": "Favorites", "index": 0, "parentId": "root"},
        "k": {"id": "k", "type": "bookmark", "title": "Kagi", "url": "https://kagi.example/", "index": 0, "parentId": "fav"},
        "r": {"id": "r", "type": "bookmark", "title": "Recipes", "url": "https://recipes.example/", "index": 1, "parentId": "root"},
    }
    Path(f"{folder}/favourites.plist").write_bytes(plistlib.dumps(items, fmt=plistlib.FMT_BINARY))
    db = sqlite3.connect(f"{folder}/history")
    db.execute("CREATE TABLE history_items (ID INTEGER PRIMARY KEY, URL TEXT, TITLE TEXT, VISIT_COUNT INTEGER, LAST_VISIT_TIME)")
    db.executemany("INSERT INTO history_items VALUES (?,?,?,?,?)", [
        (1, "https://visited.example/", "Visited", 4, 785000000),
        (2, "https://later.example/", "Later", 1, "2026-11-01 10:00:00"),
    ])
    db.commit(); db.close()


def gecko(name):
    folder = f"{sv.SUPPORT}/Import/{name}/Profiles/probe.default"
    os.makedirs(folder, exist_ok=True)
    sqlite3.connect(f"{folder}/places.sqlite").execute("CREATE TABLE IF NOT EXISTS t (x)").connection.close()


def main():
    t = sv.T()
    try:
        sv.setup()
        whale(); orion()
        for name in ["Floorp", "LibreWolf", "Waterfox", "MullvadBrowser"]: gecko(name)
        sv.launch()
        found = [b["name"] for b in sv.cmd({"do": "import-preview"})["browsers"]]
        for name in ["Naver Whale", "Orion", "Floorp", "LibreWolf", "Waterfox", "Mullvad Browser"]:
            t.ok(f"{name} is found", name in found, found)
        t.ok("each once", len(found) == len(set(found)), found)
        can = {b["name"]: b.get("can") for b in sv.cmd({"do": "import-preview"})["browsers"]}
        t.ok("Orion says what it can bring", can.get("Orion") == ["bookmarks", "history"], can.get("Orion"))
        t.ok("Whale too", can.get("Naver Whale") == ["bookmarks", "history", "open tabs"], can.get("Naver Whale"))

        out = sv.cmd({"do": "import", "from": "Naver Whale", "what": ["bookmarks"]})
        t.ok("Whale's bookmarks came", (out.get("bookmarks") or {}).get("added") == 2, out.get("bookmarks"))

        out = sv.cmd({"do": "import", "from": "Orion", "what": ["bookmarks", "history"]})
        t.ok("Orion's bookmarks came", (out.get("bookmarks") or {}).get("added") == 2, out.get("bookmarks"))
        t.ok("Orion's history came", out.get("places") == 2, out.get("places"))
        again = sv.cmd({"do": "import", "from": "Orion", "what": ["bookmarks"]})
        t.ok("nothing twice", (again.get("bookmarks") or {}).get("added") == 0, again.get("bookmarks"))
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
