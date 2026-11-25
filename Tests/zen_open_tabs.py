"""Zen's open tabs, each in the space it was open in (idea 1116).

Build first (`./build.sh debug`), then, hidden and under the probe lock:
`lockf -t 900 /private/tmp/claude-501/search-probe.lock python3 Tests/zen_open_tabs.py`.
A made-up Zen profile in the shape Zen keeps since its window sync — three
spaces, each with pinned and open tabs, Essentials, a folder, a group, an
empty tab and a glance — is written into the world's own Import folder
(never a real browser's), and brought in as the sheet does with both
switches on: its spaces, then its open tabs. Three ways the profile can
stand: Zen running with its window open; its last window closed while Zen
stays open, as a Mac app does (the session store then holds the window
under _closedWindows only); and no session store at all beside Zen's own
zen-sessions.jsonlz4.
"""
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import zen_spaces as zs  # noqa: E402
from zen_spaces import mozlz4, tab, profile  # noqa: E402
import split_view as sv  # noqa: E402

sv.use("zen-open-tabs")

W, P, R = "{6a0e3a51-0d8c-4b7e-9f32-0c1d6b2f1a01}", "{b7c1d2e3-4f50-4a61-8b72-93a4b5c6d702}", "{c8d9eaf0-1a2b-4c3d-9e4f-5a6b7c8d9e03}"


def empty(space):
    t = tab("about:blank", "New Tab", space)
    t["zenIsEmpty"] = True
    return t


TABS = [
    tab("https://mail.example/", "Mail", essential=True),
    tab("https://docs.example/", "Docs", W, pinned=True),
    tab("https://paper.example/", "Paper", W, pinned=True, group="f1"),
    tab("https://game.example/", "Game", P, pinned=True),
    tab("https://news.example/", "News", R, pinned=True),
    tab("https://work-one.example/", "Work one", W, group="g1"),
    tab("https://work-two.example/", "Work two", W, group="g1"),
    tab("https://work-three.example/", "Work three", W),
    empty(W),
    tab("https://play-one.example/", "Play one", P),
    tab("https://play-two.example/", "Play two", P),
    empty(P),
    tab("https://read-one.example/", "Read one", R),
    dict(tab("https://glance.example/", "Glance", R), zenIsGlance=True),
]
SPACES = [
    {"uuid": W, "name": "Zen Work", "icon": "💼", "theme": {"gradientColors": [{"c": [66, 133, 244], "isPrimary": True}]}},
    {"uuid": P, "name": "Zen Play", "icon": "🎮", "theme": {"gradientColors": [{"c": [208, 64, 80], "isPrimary": True}]}},
    {"uuid": R, "name": "Zen Read", "icon": "📚"},
]
FOLDERS = [{"id": "f1", "name": "Research", "pinned": True, "parentId": None, "workspaceId": W}]
GROUPS = [{"id": "g1", "name": "Reading", "collapsed": False}, {"id": "f1", "name": "Research", "pinned": True}]
OPEN = {"Zen Work": ["https://work-one.example/", "https://work-two.example/", "https://work-three.example/"],
        "Zen Play": ["https://play-one.example/", "https://play-two.example/"],
        "Zen Read": ["https://read-one.example/"]}


def zen(store):
    folder = f"{sv.SUPPORT}/Import/zen/Profiles/probe.Default (release)"
    profile(folder)
    Path(f"{folder}/zen-sessions.jsonlz4").write_bytes(mozlz4(
        {"spaces": SPACES, "folders": FOLDERS, "groups": GROUPS, "tabs": TABS, "lastCollected": 1}))
    window = {"tabs": TABS, "groups": GROUPS, "folders": FOLDERS, "spaces": SPACES, "activeZenSpace": W}
    if store == "open":
        top = {"windows": [window], "_closedWindows": []}
    elif store == "closed":
        top = {"windows": [], "_closedWindows": [window]}
    else:
        return
    Path(f"{folder}/sessionstore-backups/recovery.jsonlz4").write_bytes(mozlz4(top))


def rows(names):
    """Each space's open tabs, by its name, as the window holds them: each
    space gone to in turn (hidden), its row read."""
    out = {}
    for i, name in enumerate(names):
        sv.cmd({"do": "space", "action": "go", "index": i + 1})
        time.sleep(0.4)
        tabs = sv.cmd({"do": "tabs"})["tabs"]
        out[name] = [t.get("url") or t.get("page") for t in tabs]
    return out


def case(t, store):
    print(f"-- Zen's session store: {store}")
    sv.quit()
    sv.setup()
    zen(store)
    sv.launch()
    arc = sv.cmd({"do": "import", "from": "Zen", "what": ["spaces"]}).get("arc") or {}
    t.ok(f"[{store}] three spaces made", arc.get("spaces") == 3, arc)
    got = sv.cmd({"do": "import", "from": "Zen", "what": ["tabs"]}).get("tabs") or {}
    t.ok(f"[{store}] six open tabs read", got.get("read") == 6, got)
    t.ok(f"[{store}] six open tabs added", got.get("added") == 6, got)
    found = rows(arc.get("names") or [])
    for name, urls in OPEN.items():
        mine = [u for u in found.get(name, []) if any(u == x for v in OPEN.values() for x in v)]
        t.ok(f"[{store}] {name} holds its own open tabs", mine == urls, found)
    if store == "open":
        # Kept: quit and started again, every space still holds its own.
        sv.quit()
        sv.launch()
        again = rows(arc.get("names") or [])
        for name, urls in OPEN.items():
            t.ok(f"[{store}] {name} keeps them after a relaunch", all(u in again.get(name, []) for u in urls), again)


def main():
    t = sv.T()
    try:
        for store in ["open", "closed", "zen-only"]:
            case(t, store)
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
