"""Arc's folders survive an import made with tab groups off (#478).

Build first (`./build.sh`), then `python3 Tests/arc_folders.py`. A made-up Arc
profile is written into the world's own Import folder, with two folders of
pinned pages, and the import is asked for its spaces with tab groups off. The
names have to be in the session all the same, so that turning groups on later
shows them rather than finding nothing left.
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

FOLDERS = {
    "Basics": [("Example", "https://example.com/"), ("IANA", "https://www.iana.org/")],
    "SRE": [("Docs", "https://www.rfc-editor.org/")],
}


def arc():
    """Arc as this world will find it: one space whose pinned list is two
    folders of pages."""
    root = f"{sv.SUPPORT}/Import/Arc"
    profile = f"{root}/User Data/Default"
    os.makedirs(profile, exist_ok=True)

    items = [{"id": "pinnedBox", "childrenIds": []}]
    for folder, pages in FOLDERS.items():
        box = f"box-{folder}"
        items[0]["childrenIds"].append(box)
        kids = []
        for n, (title, url) in enumerate(pages):
            tab = f"{box}-{n}"
            kids.append(tab)
            items.append({"id": tab, "title": title,
                          "data": {"tab": {"savedURL": url, "savedTitle": title}}})
        items.append({"id": box, "title": folder, "data": {"list": {}}, "childrenIds": kids})

    sidebar = {"sidebar": {"containers": [{
        "spaces": [{"title": "Fixture", "profile": {"default": {}},
                    "containerIDs": ["pinned", "pinnedBox"]}],
        "items": items,
    }]}}
    Path(f"{root}/StorableSidebar.json").write_text(json.dumps(sidebar))
    # A profile counts as one once it holds one of the files a browser keeps.
    Path(f"{profile}/History").write_bytes(b"")


def session():
    return json.load(open(f"{sv.SUPPORT}/session.json"))


def names(shape):
    return sorted(g["name"] for g in (shape.get("groups") or []))


def grouped(shape):
    return sum(1 for t in shape["tabs"] if t.get("groupID"))


def main():
    t = sv.T()
    try:
        sv.setup()                      # tab groups are off, as they are by default
        arc()
        sv.launch()
        out = sv.cmd({"do": "import", "from": "Arc", "what": ["spaces"]})
        count = (out.get("arc") or {}).get("tabs")
        t.ok("the pages came in", count == 3, out)
        for _ in range(25):
            if names(session()): break
            time.sleep(0.2)
        shape = session()
        t.ok("their folders are in the session, with groups off",
             names(shape) == ["Basics", "SRE"], shape.get("groups"))
        t.ok("and every page is in one", grouped(shape) == 3, grouped(shape))

        # Turning groups on later finds them waiting.
        subprocess.run(["defaults", "write", sv.SUITE, "tabs.groups", "-bool", "true"])
        sv.quit()                       # quit, not finish: the world has to stay
        time.sleep(1)
        sv.launch()
        shape = session()
        t.ok("the names are still there once groups are on",
             names(shape) == ["Basics", "SRE"] and grouped(shape) == 3, shape.get("groups"))
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
