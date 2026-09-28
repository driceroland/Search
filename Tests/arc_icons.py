"""Icons for what Arc's side of an import brings in, in a hidden probe (#416).

Build first (`./build.sh`), then `python3 Tests/arc_icons.py`. A made-up Arc
profile is written into the world's own Import folder, with the one file Arc
keeps its icons in, and the import is asked for its spaces. What the pins and
the pinned tabs wear has to be there without a page ever being opened, which
is the only other way an icon arrives.
"""
import json
import os
import sqlite3
import struct
import sys
import time
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

PAGES = {"https://example.com/": (220, 40, 40), "https://www.iana.org/": (40, 90, 220)}


def png(rgb, side=16):
    """A small square of one colour, so nothing here needs a library."""
    rows = b"".join(b"\x00" + bytes(rgb) * side for _ in range(side))

    def chunk(tag, body):
        both = tag + body
        return struct.pack(">I", len(body)) + both + struct.pack(">I", zlib.crc32(both) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", side, side, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows))
            + chunk(b"IEND", b""))


def arc():
    """Arc as this world will find it: one space with a pinned tab, one
    favourite, and the icons for both in its own store."""
    root = f"{sv.SUPPORT}/Import/Arc"
    profile = f"{root}/User Data/Default"
    os.makedirs(profile, exist_ok=True)
    sidebar = {"sidebar": {"containers": [{
        "spaces": [{"title": "Fixture", "profile": {"default": {}},
                    "containerIDs": ["pinned", "pinnedBox"]}],
        "topAppsContainerIDs": [{"default": {}}, "favBox"],
        "items": [
            {"id": "pinnedBox", "childrenIds": ["t1"]},
            {"id": "t1", "title": "Example",
             "data": {"tab": {"savedURL": "https://example.com/", "savedTitle": "Example"}}},
            {"id": "favBox", "childrenIds": ["t2"]},
            {"id": "t2", "title": "IANA",
             "data": {"tab": {"savedURL": "https://www.iana.org/", "savedTitle": "IANA"}}},
        ],
    }]}}
    Path(f"{root}/StorableSidebar.json").write_text(json.dumps(sidebar))

    db = sqlite3.connect(f"{profile}/Favicons")
    db.execute("CREATE TABLE icon_mapping (id INTEGER PRIMARY KEY, page_url TEXT, icon_id INTEGER)")
    db.execute("CREATE TABLE favicon_bitmaps (id INTEGER PRIMARY KEY, icon_id INTEGER,"
               " image_data BLOB, width INTEGER, height INTEGER)")
    for n, (url, rgb) in enumerate(PAGES.items(), start=1):
        db.execute("INSERT INTO icon_mapping (page_url, icon_id) VALUES (?, ?)", (url, n))
        db.execute("INSERT INTO favicon_bitmaps (icon_id, image_data, width, height) VALUES (?, ?, 32, 32)",
                   (n, sqlite3.Binary(png(rgb))))
    db.commit()
    db.close()
    # A profile counts as one once it holds one of the files a browser keeps.
    sqlite3.connect(f"{profile}/History").close()


def kept():
    folder = Path(f"{sv.SUPPORT}/icons")
    return sorted(p.name for p in folder.glob("*.png")) if folder.is_dir() else []


def main():
    t = sv.T()
    try:
        sv.setup()
        arc()
        sv.launch()
        seen = sv.cmd({"do": "import-preview"})
        t.ok("the made-up Arc is found", any(b["name"] == "Arc" for b in seen.get("browsers", [])), seen)
        out = sv.cmd({"do": "import", "from": "Arc", "what": ["spaces"]})
        arc_counts = out.get("arc") or {}
        t.ok("its favourite is a pin and its pinned tab came too",
             arc_counts.get("pins") == 1 and arc_counts.get("tabs") == 1, out)
        # The icons are read and kept off the main queue, so they land a
        # moment after the import answers.
        for _ in range(50):
            if len(kept()) >= 2: break
            time.sleep(0.2)
        t.ok("both wear Arc's icon, with no page opened",
             kept() == ["example.com.png", "www.iana.org.png"], kept())
        t.ok("nothing was fetched: no tab holds a page",
             all(tab.get("asleep") or tab.get("hollow") for tab in sv.cmd({"do": "tabs"}).get("tabs", [])
                 if tab.get("url", "").startswith("http")),
             sv.cmd({"do": "tabs"}).get("tabs"))
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
