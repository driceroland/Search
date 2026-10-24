"""Arc's folders, in every space, survive ⌘Q and a relaunch.

Build first (`./build.sh`), then `python3 Tests/spaces_quit_keep.py`. A
made-up Arc profile with two spaces, each with a loose pinned page and a
folder of two, is imported into a hidden probe (tab groups on); the probe
goes through the spaces, quits the way ⌘Q does, and is started again, twice.
Every space's file and row must still hold its folder as a group with both
its pages.

Then the same with Settings › General › Start with a fresh window on, which
is where they were lost (Varun, 1.0.5): a fresh start kept each space's pins
and nothing else, so every folder Arc had went at the next launch. Now it
keeps what tabs that close themselves keep: pins, groups, named tabs. And a
space gone to after a fresh start opens on an empty tab, not its first pin.

Nothing here makes, shows or brings forward a window.
"""
import glob
import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("hub-sp-quit")

SPACES = {
    "Work": {"loose": [("Ex", "https://example.com/")],
             "folders": {"Basics": [("IANA", "https://www.iana.org/"), ("RFC", "https://www.rfc-editor.org/")]}},
    "Study": {"loose": [("W3", "https://www.w3.org/")],
              "folders": {"Reading": [("WHATWG", "https://whatwg.org/"), ("MDN", "https://developer.mozilla.org/")]}},
}
FOLDERS = {name: next(iter(s["folders"])) for name, s in SPACES.items()}
PAGES = {name: sorted(u for _, u in next(iter(s["folders"].values()))) for name, s in SPACES.items()}


def arc():
    """Two Arc spaces, each a loose page and one folder of two, and a
    favourite above them."""
    root = f"{sv.SUPPORT}/Import/Arc"
    profile = f"{root}/User Data/Default"
    os.makedirs(profile, exist_ok=True)
    items, spaces = [], []
    for name, s in SPACES.items():
        box = f"pin-{name}"
        kids = []
        for i, (title, url) in enumerate(s["loose"]):
            kids.append(f"{box}-l{i}")
            items.append({"id": kids[-1], "title": title, "data": {"tab": {"savedURL": url, "savedTitle": title}}})
        for folder, pages in s["folders"].items():
            fid = f"{box}-{folder}"
            kids.append(fid)
            inside = []
            for i, (title, url) in enumerate(pages):
                inside.append(f"{fid}-{i}")
                items.append({"id": inside[-1], "title": title, "data": {"tab": {"savedURL": url, "savedTitle": title}}})
            items.append({"id": fid, "title": folder, "data": {"list": {}}, "childrenIds": inside})
        items.append({"id": box, "childrenIds": kids})
        spaces.append({"title": name, "profile": {"default": {}}, "containerIDs": ["pinned", box]})
    items.append({"id": "fav", "childrenIds": ["fav-0"]})
    items.append({"id": "fav-0", "title": "GH", "data": {"tab": {"savedURL": "https://github.com/", "savedTitle": "GH"}}})
    sidebar = {"sidebar": {"containers": [{"spaces": spaces, "items": items,
                                           "topAppsContainerIDs": [{"default": {}}, "fav"]}]}}
    Path(f"{root}/StorableSidebar.json").write_text(json.dumps(sidebar))
    Path(f"{profile}/History").write_bytes(b"")


def ids():
    """The spaces by name, from the world's own list."""
    return {s["name"]: s["id"] for s in json.load(open(f"{sv.SUPPORT}/spaces.json"))}


def kept(name):
    """What a space's file holds: its groups by name, and the pages in each."""
    shape = json.load(open(f"{sv.SUPPORT}/session-{ids()[name]}.json"))
    groups = {g["id"]: g["name"] for g in shape.get("groups") or []}
    out = {}
    for e in shape["tabs"]:
        if e.get("groupID") in groups:
            out.setdefault(groups[e["groupID"]], []).append(e["url"])
    return {k: sorted(v) for k, v in out.items()}, [e["url"] for e in shape["tabs"]]


def go(name):
    index = list(ids()).index(name) + 1
    sv.cmd({"do": "space", "action": "go", "index": index})
    time.sleep(1)
    return sv.cmd({"do": "tabs"})["tabs"]


def row_groups(tabs):
    out = {}
    for tab in tabs:
        if tab["group"]:
            out.setdefault(tab["group"], 0)
            out[tab["group"]] += 1
    return out


def run(t, fresh):
    tag = "fresh: " if fresh else ""
    sv.setup(**{"tabs.groups": True, "start.fresh": fresh})
    arc()
    sv.launch()
    out = sv.cmd({"do": "import", "from": "Arc", "what": ["spaces"]}).get("arc") or {}
    t.ok(tag + "the two spaces and their pages came in", out.get("spaces") == 2 and out.get("tabs") == 6, out)
    time.sleep(1.5)
    for name in SPACES:
        go(name)
    for turn in (1, 2):
        sv.quit()
        time.sleep(1)
        for name in SPACES:
            groups, urls = kept(name)
            t.ok(f"{tag}quit {turn}: {name}'s folder is in its file, both pages",
                 groups == {FOLDERS[name]: PAGES[name]}, (groups, urls))
        sv.launch()
        time.sleep(1)
        for name in SPACES:
            tabs = go(name)
            t.ok(f"{tag}relaunch {turn}: {name} shows its folder with both pages",
                 row_groups(tabs) == {FOLDERS[name]: 2}, [(x["title"], x["group"]) for x in tabs])
            loose = any(x["title"] in ("Ex", "W3", "Example Domain", "W3C") for x in tabs)
            if fresh:
                # Last time's loose tabs go, as the switch says.
                t.ok(f"{tag}relaunch {turn}: {name}'s loose page is gone", not loose, [x["title"] for x in tabs])
                if turn == 1:
                    st = sv.sp("state")
                    f = next((x for x in st["tabs"] if x["id"] == st["activeID"]), None)
                    t.ok(f"{tag}relaunch {turn}: {name} opens on an empty tab, not its pin",
                         f is not None and f["blank"] and f["id"] not in st["pins"], (f, st["pins"]))
            else:
                t.ok(f"{tag}relaunch {turn}: {name}'s loose page is still there", loose, [x["title"] for x in tabs])
    sv.finish()


def main():
    t = sv.T()
    try:
        run(t, fresh=False)
        run(t, fresh=True)
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
