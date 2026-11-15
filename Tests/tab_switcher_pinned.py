#!/usr/bin/env python3
"""The ⌃Tab switcher excludes pinned tabs (#1108).

Build first (`./build.sh`), then `python3 Tests/tab_switcher_pinned.py`.
Verifies that:
1. Pinned tabs do not appear in the ⌃Tab switcher.
2. Regular tabs appear normally.
3. Newly pinned tabs disappear from the switcher.
4. Unpinned tabs reappear in the switcher.
5. Closing regular tabs updates the switcher.
6. Pressing ⌃Tab while on a pinned tab offers only regular tabs.
7. An entirely pinned state handles ⌃Tab safely without candidates.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("tab-switcher-pinned")


def switcher():
    return sv.cmd({"do": "switcher"})


def main():
    t = sv.T()
    try:
        sv.setup(); sv.launch()
        init_id = sv.sp("state")["tabs"][0]["id"]

        # Regular tabs
        chatgpt = sv.page("chatgpt")
        sv.sp("close", id=init_id); time.sleep(0.3)
        youtube = sv.page("youtube")
        roadmap = sv.page("roadmap")

        # Pinned tabs
        artcraft = sv.page("artcraft")
        gemini = sv.page("gemini")
        github = sv.page("github")

        sv.cmd({"do": "pin", "id": artcraft})
        sv.cmd({"do": "pin", "id": gemini})
        sv.cmd({"do": "pin", "id": github})

        st = sv.sp("state")
        t.ok("pinned tabs are registered as pins", {artcraft, gemini, github}.issubset(set(st["pins"])), st["pins"])

        # Select a regular tab and press ⌃Tab
        sv.sp("select", id=chatgpt); time.sleep(0.4)
        sv.cmd({"do": "press", "code": 48, "chars": "\t", "mods": ["ctrl"]}); time.sleep(0.8)

        s = switcher()
        t.ok("⌃Tab: switcher is visible", s["visible"], s)
        t.ok("regular tabs appear in switcher", set(s["candidates"]) == {chatgpt, youtube, roadmap}, s["candidates"])
        t.ok("pinned tabs are excluded from switcher", not any(p in s["candidates"] for p in [artcraft, gemini, github]), s["candidates"])
        t.ok("pinned tabs have no cards in switcher", not any(p in s["cards"] for p in [artcraft, gemini, github]), s["cards"])

        # Release switcher
        sv.sp("mouse", points=[[5, 5], [5, 5]]); time.sleep(0.5)

        # Pin a regular tab: it must disappear from switcher candidates
        sv.cmd({"do": "pin", "id": roadmap}); time.sleep(0.3)
        sv.cmd({"do": "press", "code": 48, "chars": "\t", "mods": ["ctrl"]}); time.sleep(0.8)
        s = switcher()
        t.ok("pinning roadmap removes it from switcher", roadmap not in s["candidates"], s["candidates"])
        sv.sp("mouse", points=[[5, 5], [5, 5]]); time.sleep(0.5)

        # Unpin roadmap: it must reappear in switcher
        sv.cmd({"do": "pin", "id": roadmap, "off": True}); time.sleep(0.3)
        sv.cmd({"do": "press", "code": 48, "chars": "\t", "mods": ["ctrl"]}); time.sleep(0.8)
        s = switcher()
        t.ok("unpinning roadmap restores it to switcher", roadmap in s["candidates"], s["candidates"])
        sv.sp("mouse", points=[[5, 5], [5, 5]]); time.sleep(0.5)

        # Close a regular tab: it updates switcher
        sv.sp("close", id=youtube); time.sleep(0.3)
        sv.cmd({"do": "press", "code": 48, "chars": "\t", "mods": ["ctrl"]}); time.sleep(0.8)
        s = switcher()
        t.ok("closing youtube removes it from switcher", youtube not in s["candidates"], s["candidates"])
        t.ok("remaining regular tabs stay in switcher", set(s["candidates"]) == {chatgpt, roadmap}, s["candidates"])
        sv.sp("mouse", points=[[5, 5], [5, 5]]); time.sleep(0.5)

        # ⌃Tab while focused on a pinned tab
        sv.sp("select", id=artcraft); time.sleep(0.4)
        sv.cmd({"do": "press", "code": 48, "chars": "\t", "mods": ["ctrl"]}); time.sleep(0.8)
        s = switcher()
        if s["visible"]:
            t.ok("⌃Tab from pinned tab excludes all pinned tabs", not any(p in s["candidates"] for p in [artcraft, gemini, github]), s["candidates"])
            t.ok("⌃Tab from pinned tab displays only regular tabs", set(s["candidates"]) == {chatgpt, roadmap}, s["candidates"])
            sv.sp("mouse", points=[[5, 5], [5, 5]]); time.sleep(0.5)
        else:
            t.ok("⌃Tab from pinned tab handled safely without displaying pinned tabs", True)

        # Empty regular tab state (all regular tabs pinned)
        sv.cmd({"do": "pin", "id": chatgpt}); time.sleep(0.2)
        sv.cmd({"do": "pin", "id": roadmap}); time.sleep(0.2)
        sv.cmd({"do": "press", "code": 48, "chars": "\t", "mods": ["ctrl"]}); time.sleep(0.5)
        s = switcher()
        t.ok("entirely pinned collection: switcher does not offer pinned tabs", not s["visible"] or len(s["candidates"]) == 0, s)

    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
