"""Moving on: Export Spaces, and spaces from Ardia, Yab and Dia.

Build first (`./build.sh`), then `python3 Tests/spaces_moving_on.py`. Hidden
probe worlds only (SEARCH_PROBE, see split_view.use), one at a time; nothing
shows, nothing plays. Every browser's files are made up here, in the
world's own Import folder: no real browser's data and no keychain is read.

1. A world seeded with two spaces — squares, rows in nested folders, pins
   every space shows, open tabs in a group — exports a bookmarks page and
   Search's own spaces file. A fresh world brings the spaces file in, and
   exports again: the two must match. The bookmarks page comes in as
   bookmarks, a folder per space.
2. A fresh world finds Ardia, Yab and Dia (Dia's sidebar encrypted as
   SQLCipher 4 keeps it, its key in the made-up "Safe Storage" file a test
   run reads instead of the keychain) and brings each one's spaces.
"""
import base64
import hashlib
import hmac
import json
import os
import shutil
import sqlite3
import subprocess
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


# MARK: - the other browsers, made up

def ardia(base):
    root = base / "com.ardia.browser"
    (root / "Chromium/Default").mkdir(parents=True)
    (root / "Chromium/Default/History").write_bytes(b"")
    (root / "session.json").write_text(json.dumps({
        "profileOrder": ["default", "p2"],
        "profiles": {"default": {"name": "Ardia Home", "icon": "symbol:house"},
                     "p2": {"name": "Ardia Side", "dataId": "default", "color": "blue"}},
        "windows": [{"id": "w", "tabIds": ["a", "b", "c"]}],
        "tabs": [{"id": "a", "profileId": "default", "pin": {"as": "tile"}, "url": "https://tile.example.com/", "title": "Tile"},
                 {"id": "b", "profileId": "default", "pin": {"as": "row"}, "url": "https://row.example.com/", "title": "Row"},
                 {"id": "c", "profileId": "p2", "pin": {"as": "row"}, "url": "https://side.example.com/", "title": "Side"}],
        "groups": [{"id": "g", "name": "Ardia folder", "pinned": True, "tabIds": ["b"]}],
    }))


def yab(base):
    root = base / "Yab"
    shared = "space-" + FIRST
    (root / "Chromium" / shared).mkdir(parents=True)
    (root / "Chromium" / shared / "History").write_bytes(b"")
    (root / "spaces.json").write_text(json.dumps([{"id": FIRST, "name": "Yab One", "icon": "🎮"},
                                                  {"id": "BBBB", "name": "Yab Two"}]))
    (root / "session.json").write_text(json.dumps({"tabs": [
        {"pin": "tile", "url": "https://ytile.example.com/", "title": "Y tile"},
        {"kept": True, "url": "https://ykept.example.com/", "title": "Y kept", "folder": "f", "folderName": "Yab folder"}]}))
    (root / "session-BBBB.json").write_text(json.dumps({"tabs": [{"kept": True, "url": "https://two.example.com/", "title": "Two"}]}))


SALT_KEY = base64.b64decode("iOe1Ue/XtonbieE/5m1nAgewvWQlePHRcKnoU10EyOM=")


def dia(base):
    """Dia's sidebar database, encrypted with the made-up secret."""
    profile = base / "Dia/User Data/Default"
    profile.mkdir(parents=True)
    (profile / "History").write_bytes(b"")
    secret = "search-probe-secret"
    (base / "Dia/User Data/Safe Storage").write_text(secret)
    with tempfile.TemporaryDirectory() as tmp:
        plain = os.path.join(tmp, "tabs.db")
        schema = """
        CREATE TABLE spaces (id TEXT PRIMARY KEY, title TEXT, creation_date TEXT, theme TEXT);
        CREATE TABLE nodes (id INTEGER PRIMARY KEY, kind TEXT, entity_id TEXT, parent_id INTEGER, "order" INTEGER, deleted_at TEXT, space_id TEXT);
        CREATE TABLE tab_groups (id TEXT PRIMARY KEY, title TEXT);
        CREATE TABLE content_panes (id TEXT PRIMARY KEY, custom_title TEXT);
        CREATE TABLE web_contents (id INTEGER PRIMARY KEY, content_pane_id TEXT, url TEXT, title TEXT);
        """
        subprocess.run(["sqlite3", plain, ".filectrl reserve_bytes 80", schema], check=True, capture_output=True)
        db = sqlite3.connect(plain)
        db.executescript("""
        INSERT INTO spaces VALUES ('s1', 'Dia Home', '2026-10-01', 'green'), ('s2', 'Dia Work', '2026-10-02', 'neutral');
        INSERT INTO nodes VALUES (1, 'pinned_container', 'pc1', NULL, 0, NULL, 's1'), (2, 'pinned_container', 'pc2', NULL, 1, NULL, 's2'),
          (3, 'favorites', 'f', NULL, 2, NULL, 's1'), (4, 'tab', 't1', 3, 0, NULL, 's1'), (5, 'content_pane', 'p1', 4, 0, NULL, 's1'),
          (6, 'group', 'g1', 1, 0, NULL, 's1'), (7, 'tab', 't2', 6, 0, NULL, 's1'), (8, 'content_pane', 'p2', 7, 0, NULL, 's1'),
          (9, 'tab', 't3', 2, 0, NULL, 's2'), (10, 'content_pane', 'p3', 9, 0, NULL, 's2');
        INSERT INTO tab_groups VALUES ('g1', 'Dia folder');
        INSERT INTO content_panes VALUES ('p1', NULL), ('p2', NULL), ('p3', NULL);
        INSERT INTO web_contents (content_pane_id, url, title) VALUES ('p1', 'https://dfav.example.com/', 'D fav'),
          ('p2', 'https://dpin.example.com/', 'D pin'), ('p3', 'https://dwork.example.com/', 'D work');
        """)
        db.commit(); db.close()
        raw = open(plain, "rb").read()
    root = hashlib.pbkdf2_hmac("sha1", secret.encode(), b"saltysalt", 1003, 16)
    label = b"profile/Default/tabs"
    prk = hmac.new(hmac.new(SALT_KEY, label, hashlib.sha256).digest(), root, hashlib.sha256).digest()
    key = hmac.new(prk, label + b"\x01", hashlib.sha256).digest()
    assert raw[20] == 80, "sqlite3 kept the 80 bytes"
    out = b""
    for i in range(len(raw) // 4096):
        page = raw[i * 4096:(i + 1) * 4096]
        start = 16 if i == 0 else 0
        iv = os.urandom(16)
        body = subprocess.run(["openssl", "enc", "-e", "-aes-256-cbc", "-nopad", "-K", key.hex(), "-iv", iv.hex()],
                              input=page[start:4096 - 80], capture_output=True, check=True).stdout
        out += (os.urandom(16) if i == 0 else b"") + body + iv + bytes(64)
    (profile / "tabs.db").write_bytes(out)


def importers(t):
    sv.use("moving-on-import")
    try:
        sv.setup(**PREFS)
        base = Path(sv.SUPPORT) / "Import"
        ardia(base); yab(base); dia(base)
        sv.launch()
        preview = sv.cmd({"do": "import-preview"})
        found = {b["name"]: b for b in preview["browsers"]}
        for name in ["Ardia", "Yab", "Dia"]:
            t.ok(f"{name} is found, with spaces to bring", name in found and "spaces & pins" in found[name]["can"], list(found))
        t.ok("counting asked for no key", preview.get("keyAskedEver") == 0, preview.get("keyAskedEver"))
        expect = {"Ardia": (["Ardia Home", "Ardia Side"], 2), "Yab": (["Yab One", "Yab Two"], 2), "Dia": (["Dia Home", "Dia Work"], 2)}
        for name, (spaces, made) in expect.items():
            out = sv.cmd({"do": "import", "from": name, "profile": "all", "what": ["spaces"]})
            arc = out.get("arc")
            t.ok(f"{name}'s spaces came in", isinstance(arc, dict) and all(s in arc["names"] for s in spaces) and arc["spaces"] == made, arc)
            t.ok(f"…with their pins", isinstance(arc, dict) and arc["pins"] >= 2, arc)
        dump = shape(sv.cmd({"do": "export-spaces"})["spaces"])
        by = {s["name"]: s for s in dump}
        t.ok("Ardia's tile is a square, its folder kept",
             by["Ardia Home"]["squares"] == [("Tile", "https://tile.example.com/")]
             and ("Ardia folder", "Row", "https://row.example.com/") in by["Ardia Home"]["rows"], by.get("Ardia Home"))
        t.ok("Yab's kept tab is in its folder", ("Yab folder", "Y kept", "https://ykept.example.com/") in by["Yab One"]["rows"], by.get("Yab One"))
        t.ok("Dia's folder and favourite came", ("Dia folder", "D pin", "https://dpin.example.com/") in by["Dia Home"]["rows"]
             and by["Dia Home"]["squares"] == [("D fav", "https://dfav.example.com/")], by.get("Dia Home"))
    finally:
        sv.finish()


def main():
    t = sv.T()
    try:
        export_round_trip(t)
        importers(t)
    finally:
        t.done()
        shutil.rmtree(OUT, ignore_errors=True)
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
