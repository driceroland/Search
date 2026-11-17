#!/usr/bin/env python3
"""Live folders in pinned rows, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/live_folders.py`. The feed is
split_view.py's own local server (/feed.xml, and /blog pointing at it);
nothing leaves the Mac and nothing is shown. LiveFoldersTests holds the
reading; this holds the folder in a real window: made from a page's
address, its posts drawn and opened, refreshed, kept over a relaunch, and
never taking a pin.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("live-folders")
t = sv.T()


def pf(**f): return sv.cmd({"do": "pinfolder", **f})


def live(st, name="Probe Feed"):
    return next((f for f in st.get("folders", []) if f["name"] == name), None)


try:
    sv.setup(sidebar=True); sv.launch()
    a = sv.page("a"); sv.page("front")
    pf(action="on")
    pf(action="pin", id=a)
    st = pf(action="live", url=f"{sv.BASE}/blog")
    folder = live(st)
    t.ok("a page's feed is found, and the folder takes its name", folder is not None, st.get("folders"))
    t.ok("its feed is the feed, not the page", folder and folder["feed"] == f"{sv.BASE}/feed.xml", folder)
    titles = [i[0] for i in (folder or {}).get("items", [])]
    t.ok("three posts, newest first", titles == ["Post 3", "Post 2", "Post 1"], titles)
    links = [i[1] for i in (folder or {}).get("items", [])]
    t.ok("relative links read against the feed", links and links[0] == f"{sv.BASE}/post/3", links)
    flat = [str(x) for x in st.get("lines") or []]
    t.ok("its posts are drawn under it", any("'item'" in x and "Post 3" in x for x in flat), flat)

    st = pf(action="move", id=a, folder="Probe Feed")
    t.ok("a pin can't go in a live folder: it stays at the top", ["a", None] in (st.get("saved") or []), st.get("saved"))

    st = pf(action="openitem", name="Probe Feed", title="Post 2")
    t.ok("a post opens in a tab, not as a pin", st.get("front") == {"pinned": False}, st.get("front"))

    sv.FEED_POSTS = 15
    st = pf(action="refresh", name="Probe Feed")
    titles = [i[0] for i in (live(st) or {}).get("items", [])]
    t.ok("refresh: the newest twelve", len(titles) == 12 and titles[0] == "Post 15", titles)

    pf(action="fold", name="Probe Feed")
    st = pf(action="state")
    t.ok("folded: no post drawn", not any("'item'" in str(x) for x in st.get("lines") or []), st.get("lines"))
    pf(action="open", name="Probe Feed")

    sv.quit(); sv.launch(); time.sleep(1)
    st = pf(action="state")
    folder = live(st)
    t.ok("relaunch: the folder and its posts kept", folder and len(folder.get("items", [])) == 12, folder)

    pf(action="delete", name="Probe Feed")
    st = pf(action="state")
    t.ok("delete: gone, the pin still there", live(st) is None and ["a", None] in (st.get("saved") or []), st)
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
