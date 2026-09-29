"""A favourite already pinned doesn't come in a second time (#482).

Build first (`./build.sh`), then `python3 Tests/arc_pins.py`. A made-up Arc
profile is brought in twice, with a pin sent wandering in between, the way a
site does when it answers somewhere else: Gmail pinned at mail.google.com and
found at mail.google.com/mail/u/0/. The second import must add nothing.
"""
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

FAVOURITES = [
    ("Example", "https://example.com/"),
    ("Mail", "https://mail.example.com"),
    # Two of Arc's own on one site are two favourites, not one.
    ("Example again", "https://example.com/second"),
]


def arc():
    """Arc as this world will find it: a space, and two favourites above it."""
    root = f"{sv.SUPPORT}/Import/Arc"
    profile = f"{root}/User Data/Default"
    os.makedirs(profile, exist_ok=True)
    items = [{"id": "favBox", "childrenIds": []}]
    for n, (title, url) in enumerate(FAVOURITES):
        tab = f"fav-{n}"
        items[0]["childrenIds"].append(tab)
        items.append({"id": tab, "title": title,
                      "data": {"tab": {"savedURL": url, "savedTitle": title}}})
    sidebar = {"sidebar": {"containers": [{
        "spaces": [{"title": "Fixture", "profile": {"default": {}}, "containerIDs": []}],
        "topAppsContainerIDs": [{"default": {}}, "favBox"],
        "items": items,
    }]}}
    Path(f"{root}/StorableSidebar.json").write_text(json.dumps(sidebar))
    Path(f"{profile}/History").write_bytes(b"")


def pins():
    path = f"{sv.SUPPORT}/pins.json"
    if not os.path.exists(path): return []
    return [p for row in json.load(open(path)).values() for p in row]


def wander(to):
    """A pin written down where the site answers, not where it was pinned."""
    path = f"{sv.SUPPORT}/pins.json"
    kept = json.load(open(path))
    for row in kept.values():
        for pin in row:
            if "mail.example.com" in pin["home"]: pin["home"] = to
    json.dump(kept, open(path, "w"))


def main():
    t = sv.T()
    try:
        sv.setup()
        arc()
        sv.launch()
        sv.cmd({"do": "import", "from": "Arc", "what": ["spaces"]})
        for _ in range(25):
            if len(pins()) >= 3: break
            time.sleep(0.2)
        t.ok("every favourite came in, two of them on one site",
             len(pins()) == 3, [p["home"] for p in pins()])

        sv.quit(); time.sleep(1)
        wander("https://mail.example.com/mail/u/0/#inbox")
        sv.launch()
        out = sv.cmd({"do": "import", "from": "Arc", "what": ["spaces"]})
        time.sleep(1)
        t.ok("the second import adds no pin", (out.get("arc") or {}).get("pins") == 0, out.get("arc"))
        t.ok("and there are still three", len(pins()) == 3, [p["home"] for p in pins()])
        t.ok("the one that wandered kept where it had gone",
             any(p["home"].endswith("/mail/u/0/#inbox") for p in pins()), [p["home"] for p in pins()])
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
