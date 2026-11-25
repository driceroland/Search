"""Moving on: Export Spaces.

Build first (`./build.sh`), then `python3 Tests/spaces_moving_on.py`. Hidden
probe worlds only (SEARCH_PROBE, see split_view.use), one at a time; nothing
shows, nothing plays. Every browser's files are made up here, in the
world's own Import folder: no real browser's data and no keychain is read.

1. A world seeded with two spaces — squares, rows in nested folders, pins
   every space shows, open tabs in a group — exports a bookmarks page and
   Search's own spaces file. A fresh world brings the spaces file in, and
   exports again: the two must match. The bookmarks page comes in as
   bookmarks, a folder per space.
"""
import json
import shutil
import sys
import tempfile
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

FIRST = "00000000-0000-0000-0000-000000000001"
WORK = "6A1D3C52-9F0B-4E59-A1C2-3D4B5E6F7A80"
OUT = Path(tempfile.mkdtemp(prefix="search-spaces-export-"))
PREFS = {"spaces": True, "pins.list": True, "pins.folders": True}


def pin(home, title, listed=None, folder=None):
    out = {"id": str(uuid.uuid4()).upper(), "letter": title[0], "home": home, "title": title, "titled": True}
    if listed: out["listed"] = True
    if folder: out["folder"] = folder
    return out


def seed():
    """Two spaces: Home (the first) and Work, blue with a briefcase."""
    support = Path(sv.SUPPORT)
    support.mkdir(parents=True, exist_ok=True)
    (support / "spaces.json").write_text(json.dumps([
        {"id": FIRST, "name": "Home", "colour": 0},
        {"id": WORK, "name": "Work", "colour": 1, "icon": "briefcase", "sharesSignIns": True},
    ]))
    outer, inner = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()
    (support / "pin-folders.json").write_text(json.dumps({
        WORK: [{"id": outer, "name": "Projects"}, {"id": inner, "name": "Inner", "parent": outer}],
    }))
    (support / "pins.json").write_text(json.dumps({
        FIRST: [pin("https://news.example.com/", "News"), pin("https://read.example.com/", "Reading row", listed=True)],
        WORK: [pin("https://mail.example.com/", "Mail"),
               pin("https://docs.example.com/", "Docs", listed=True, folder=outer),
               pin("https://deep.example.com/", "Deep", listed=True, folder=inner),
               pin("https://loose.example.com/", "Loose", listed=True)],
        "shared": [pin("https://cal.example.com/", "Calendar")],
    }))
    group = str(uuid.uuid4()).upper()
    (support / f"session-{WORK}.json").write_text(json.dumps({
        "active": 0, "groups": [{"id": group, "name": "Research", "collapsed": False}],
        "tabs": [{"url": "https://open.example.org/1", "title": "Open one"},
                 {"url": "https://open.example.org/2", "title": "Grouped", "groupID": group}],
    }))


def shape(dump):
    """What must survive the trip, ids left out: per space, its look, its
    squares, its rows by folder path, its open tabs by group."""
    out = []
    for profile in dump["profiles"]:
        shared = sorted((p["title"], p["url"]) for p in profile.get("everySpace", []))
        for space in profile["spaces"]:
            folders = {f["id"]: f for f in space.get("folders", [])}

            def path(fid):
                names = []
                while fid in folders and len(names) < 10:
                    names.insert(0, folders[fid]["name"]); fid = folders[fid].get("parent")
                return "/".join(names)
            groups = {g["id"]: g["name"] for g in space.get("groups", [])}
            out.append({
                "name": space["name"], "colour": space.get("colour", 0), "icon": space.get("icon"),
                "squares": [(p["title"], p["url"]) for p in space.get("pins", []) if not p.get("listed")],
                "rows": sorted((path(p.get("folder")), p["title"], p["url"]) for p in space.get("pins", []) if p.get("listed")),
                "tabs": [(t["url"], groups.get(t.get("group"))) for t in space.get("tabs", [])],
                "shared": shared,
            })
    return out


def export_round_trip(t):
    sv.use("spaces-export")
    try:
        sv.setup(**PREFS)
        seed()
        sv.launch()
        html, bundle = OUT / "spaces.html", OUT / "spaces.json"
        before = sv.cmd({"do": "export-spaces", "path": str(html)})
        sv.cmd({"do": "export-spaces", "path": str(bundle)})
        original = shape(before["spaces"])
        t.ok("the seeded world exports both spaces", [s["name"] for s in original] == ["Home", "Work"], original)
        page = html.read_text()
        t.ok("the bookmarks page is a Netscape one", page.startswith("<!DOCTYPE NETSCAPE-Bookmark-file-1>"))
        t.ok("…with the shared pins' folder first", page.index("<H3>Every Space</H3>") < page.index("<H3>Home</H3>") < page.index("<H3>Work</H3>"))
    finally:
        sv.finish()

    # A fresh world: the spaces file, brought in.
    sv.use("spaces-reimport")
    try:
        sv.setup(**PREFS)
        sv.launch()
        took = sv.cmd({"do": "import-spaces-file", "path": str(bundle)})
        t.ok("the spaces file comes in as spaces", "Work" in took["names"], took)
        after = shape(sv.cmd({"do": "export-spaces"})["spaces"])
        # A space that had no icon of its own is given one for its name.
        for space in after:
            was = next((s for s in original if s["name"] == space["name"]), None)
            if was and was["icon"] is None: space["icon"] = None
        t.ok("exported again, it is what was exported", after == original,
             json.dumps({"before": original, "after": after}, indent=1))
        marks = sv.cmd({"do": "import-file", "path": str(html)})
        t.ok("the bookmarks page comes in as a folder per space",
             all(name in marks["top"] for name in ["Every Space", "Home", "Work"]), marks.get("top"))
    finally:
        sv.finish()


def main():
    t = sv.T()
    try:
        export_round_trip(t)
    finally:
        t.done()
        shutil.rmtree(OUT, ignore_errors=True)
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
