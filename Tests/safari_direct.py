"""Safari read directly when its files open, into a probe world.

Build first (`./build.sh debug`), then, hidden and under the probe lock:
`lockf -t 900 /private/tmp/claude-501/search-probe.lock python3 Tests/safari_direct.py`.
A made-up Safari folder is written into the world's own Import folder (a
probe never reads ~/Library/Safari): its Bookmarks.plist and History.db.
"""
import os
import plistlib
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("safari-direct")


def leaf(url, title):
    return {"WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": url, "URIDictionary": {"title": title}}


def safari():
    folder = f"{sv.SUPPORT}/Import/Safari"
    os.makedirs(folder, exist_ok=True)
    tree = {"WebBookmarkType": "WebBookmarkTypeList", "Children": [
        {"WebBookmarkType": "WebBookmarkTypeList", "Title": "BookmarksBar",
         "Children": [leaf("https://bar.example/", "Bar page")]},
        {"WebBookmarkType": "WebBookmarkTypeList", "Title": "com.apple.ReadingList",
         "Children": [leaf("https://read-later.example/", "Read later")]},
    ]}
    Path(f"{folder}/Bookmarks.plist").write_bytes(plistlib.dumps(tree, fmt=plistlib.FMT_BINARY))
    db = sqlite3.connect(f"{folder}/History.db")
    db.executescript("""
    CREATE TABLE history_items (id INTEGER PRIMARY KEY, url TEXT, visit_count INTEGER);
    CREATE TABLE history_visits (id INTEGER PRIMARY KEY, history_item INTEGER, visit_time REAL, title TEXT);
    INSERT INTO history_items VALUES (1, 'https://visited.example/', 3);
    INSERT INTO history_visits VALUES (1, 1, 785000000.0, 'Visited');
    """)
    db.commit(); db.close()


def main():
    t = sv.T()
    try:
        sv.setup()
        safari()
        sv.launch()
        preview = sv.cmd({"do": "import-preview"})
        t.ok("Safari is in the list", "Safari" in [b["name"] for b in preview["browsers"]], preview["browsers"])
        t.ok("and no export note for it", preview.get("safari") is False, preview.get("safari"))
        out = sv.cmd({"do": "import", "from": "Safari", "what": ["bookmarks", "history"]})
        t.ok("its bookmarks and Reading List came", (out.get("bookmarks") or {}).get("added") == 2, out.get("bookmarks"))
        t.ok("its history came", out.get("places") == 1, out.get("places"))
        t.ok("no key asked for", sv.cmd({"do": "import-preview"}).get("keyAskedEver") == 0)
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
