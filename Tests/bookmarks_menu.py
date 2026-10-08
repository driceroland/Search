#!/usr/bin/env python3
"""The Bookmarks menu keeps its bookmarks while a tab's title keeps changing.

Build first (`./build.sh`), then `python3 Tests/bookmarks_menu.py`. SwiftUI
updates an open menu through its own delegate whenever anything it shows may
have changed, which took out the bookmarks Search adds after its items: a
download page counting its speed in its title emptied the menu under the
pointer. The menu is only ever told it opened and closed; nothing is drawn.
"""
import json
import os
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bookmarks-menu")


def menu(**f):
    return sv.cmd({"do": "menu", "peek": True, **f})


def main():
    t = sv.T()
    try:
        sv.setup()
        os.makedirs(sv.SUPPORT, exist_ok=True)
        node = lambda **f: {"id": str(uuid.uuid4()).upper(), **f}
        kept = [node(title=f"Site {i}", url=f"https://example.com/{i}") for i in range(4)]
        kept.append(node(title="Folder", children=[node(title="In", url="https://example.org/")]))
        json.dump(kept, open(f"{sv.SUPPORT}/bookmarks.json", "w"))
        sv.launch()
        a = sv.page("a")
        m = sv.cmd({"do": "menu"})
        t.ok("the menu holds the bookmarks", m["ours"] >= 5, m)
        sv.ev(a, "window.__n = 0; setInterval(() => { document.title = 'dl ' + (++window.__n) + ' MB/s' }, 150); 1")
        time.sleep(1.5)
        t.ok("closed, the title changing: SwiftUI leaves it alone", menu()["ours"] >= 5)
        menu(shown=True)
        gone = menu(swiftui=True)
        t.ok("open: SwiftUI's own update takes them out", gone["ours"] == 0, gone)
        time.sleep(0.5)
        back = menu()
        t.ok("open: they're back at once", back["ours"] >= 5, back)
        time.sleep(1.5)
        t.ok("open, the title changing: still there", menu()["ours"] >= 5)
        menu(hidden=True)
        m = sv.cmd({"do": "menu"})
        t.ok("opened again: all there", m["ours"] >= 5, m)
    finally:
        t.done(); sv.finish()
        os.system(f"defaults delete {sv.SUITE} >/dev/null 2>&1; rm -f ~/Library/Preferences/{sv.SUITE}.plist")
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
