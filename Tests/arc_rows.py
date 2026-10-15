"""Arc's pinned list: what it keeps loose becomes a row, what it filed stays
a tab in a group (#478).

Build first (`./build.sh`), then `python3 Tests/arc_rows.py`. A made-up Arc
profile holds a favourite, a page loose in its pinned list, and two filed in a
folder. With pinned rows on, the loose page has to come in as a row under the
squares and the filed ones as tabs in a group named after the folder, since a
pin is never in a group and the folder would be the thing lost. With rows off,
nothing is split.
"""
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("arc-rows")


def arc():
    """A favourite, a page Arc keeps loose, and a folder holding two."""
    root = f"{sv.SUPPORT}/Import/Arc"
    profile = f"{root}/User Data/Default"
    os.makedirs(profile, exist_ok=True)
    items = [
        {"id": "favBox", "childrenIds": ["fav"]},
        {"id": "fav", "title": "Favourite",
         "data": {"tab": {"savedURL": "https://example.com/", "savedTitle": "Favourite"}}},
        {"id": "pinnedBox", "childrenIds": ["loose", "folder"]},
        {"id": "loose", "title": "Kept",
         "data": {"tab": {"savedURL": "https://www.iana.org/", "savedTitle": "Kept"}}},
        {"id": "folder", "title": "SRE", "data": {"list": {}}, "childrenIds": ["filed1", "filed2"]},
        {"id": "filed1", "title": "One",
         "data": {"tab": {"savedURL": "https://www.rfc-editor.org/", "savedTitle": "One"}}},
        {"id": "filed2", "title": "Two",
         "data": {"tab": {"savedURL": "https://www.ietf.org/", "savedTitle": "Two"}}},
    ]
    sidebar = {"sidebar": {"containers": [{
        "spaces": [{"title": "Fixture", "profile": {"default": {}},
                    "containerIDs": ["pinned", "pinnedBox"]}],
        "topAppsContainerIDs": [{"default": {}}, "favBox"],
        "items": items,
    }]}}
    Path(f"{root}/StorableSidebar.json").write_text(json.dumps(sidebar))
    Path(f"{profile}/History").write_bytes(b"")


def pins():
    path = f"{sv.SUPPORT}/pins.json"
    if not os.path.exists(path): return []
    return [p for row in json.load(open(path)).values() for p in row]


def session():
    return json.load(open(f"{sv.SUPPORT}/session.json"))


def main():
    t = sv.T()
    try:
        # Rows on, and tab groups off, to show the folder is kept either way.
        sv.setup(**{"pins.list": True})
        arc()
        sv.launch()
        sv.cmd({"do": "import", "from": "Arc", "what": ["spaces"]})
        for _ in range(25):
            if len(pins()) >= 2: break
            time.sleep(0.2)

        rows = [p for p in pins() if p.get("listed")]
        squares = [p for p in pins() if not p.get("listed")]
        t.ok("the favourite is a square", [p["home"] for p in squares] == ["https://example.com/"], squares)
        t.ok("the page Arc kept loose is a row",
             [p["home"] for p in rows] == ["https://www.iana.org/"], rows)

        shape = session()
        groups = {g["id"]: g["name"] for g in (shape.get("groups") or [])}
        filed = [t_["url"] for t_ in shape["tabs"] if groups.get(t_.get("groupID")) == "SRE"]
        t.ok("the two it filed are tabs in a group of that name",
             sorted(filed) == ["https://www.ietf.org/", "https://www.rfc-editor.org/"], filed)
        t.ok("and the row is not a tab of its own",
             all("iana.org" not in t_["url"] or t_.get("pin") for t_ in shape["tabs"]),
             [t_["url"] for t_ in shape["tabs"]])

        # Rows off: nothing is split, the whole pinned list comes in as tabs.
        sv.finish()
        sv.setup(**{"pins.list": False})
        arc()
        sv.launch()
        sv.cmd({"do": "import", "from": "Arc", "what": ["spaces"]})
        time.sleep(1.5)
        t.ok("with rows off, no pin is kept as one", not [p for p in pins() if p.get("listed")], pins())
        loose = [t_["url"] for t_ in session()["tabs"] if "iana.org" in t_["url"]]
        t.ok("and the page Arc kept loose is a tab again", loose == ["https://www.iana.org/"], loose)
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
