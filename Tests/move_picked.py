#!/usr/bin/env python3
"""Five tabs picked in the column (⌘-click) moved together (idea 1092): into
a pin folder and into a tab group, by the tab menu and by a drag, in the
order the column shows them, and one ⌘Z puts all five back. In a hidden
probe.

Build first (`./build.sh`), then `python3 Tests/move_picked.py`. It uses the
split suite's harness: started hidden, no window made or shown, everything
removed afterwards. `split pick` makes the column's ⌘-clicks; `picked` is
the menu items' actions ("via": "menu") or the drop a drag of one of them
makes ("via": "drag", see MovePicked.swift); ⌘Z is pressed as a real key.
That the menus read "Move to Folder" and "New Folder with 5 Pins" is looked
at by hand on a release candidate.
"""
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("move-picked")
t = sv.T()


def pk(action, **f): return sv.cmd({"do": "picked", "action": action, **f})
def pf(**f): return sv.cmd({"do": "pinfolder", **f})
def pick(*ids): return sv.sp("pick", ids=list(ids))
# ⌘Z through the window's key handling with the page holding the keyboard,
# as undo_reopens.py presses it (a hidden probe has no key window).
def z_key():
    """The key code that types z on this Mac's keyboard layout (6 on QWERTY,
    13 on AZERTY), as undo_reopens.py finds it."""
    js = ('ObjC.import("AppKit"); var c = -1; for (var k = 0; k < 51 && c < 0; k++) {'
          ' var e = $.NSEvent.keyEventWithTypeLocationModifierFlagsTimestampWindowNumberContextCharactersCharactersIgnoringModifiersIsARepeatKeyCode('
          '$.NSEventTypeKeyDown, $.NSMakePoint(0, 0), 0, 0, 0, $(), "x", "x", false, k);'
          ' if (ObjC.unwrap(e.charactersByApplyingModifiers(0)) === "z") c = k; } c')
    out = subprocess.run(["osascript", "-l", "JavaScript", "-e", js], capture_output=True, text=True).stdout.strip()
    return int(out) if out.lstrip("-").isdigit() and int(out) >= 0 else 6


Z = z_key()
def cmd_z(): sv.cmd({"do": "keyeq", "code": Z, "chars": "z"}); time.sleep(0.5); return pk("state")
def snap(st): return (st["row"], st["folderOf"], st["groupOf"], st["groups"], st["folders"])


def in_order(row, ids): return [x for x in row if x in ids]


def case_folder(t):
    """five pinned rows into a folder, by the menu and by a drag, and back with ⌘Z"""
    sv.setup(sidebar=True, **{"tabs.undoReopens": True}); sv.launch()
    p = [sv.page(f"p{n}") for n in range(1, 8)]
    front = sv.page("front")
    pf(action="on")
    for id in p: pf(action="pin", id=id)
    pf(action="new", name="Work", id=p[0])
    pf(action="new", name="Docs", id=p[3])
    sv.sp("select", id=front)
    five = [p[1], p[2], p[4], p[5], p[6]]
    st = pick(*five)
    t.ok("pick: five pinned rows", sorted(st["selected"]) == sorted(five), st["selected"])
    before = pk("state")
    order = in_order(before["row"], five)

    st = pk("folder", name="Work", via="menu")
    t.ok("menu: all five in Work", all(st["folderOf"][x] == "Work" for x in five), st["folderOf"])
    t.ok("menu: in the order they had", in_order(st["row"], five) == order, (order, st["row"]))
    t.ok("menu: Work's first pin stays first", in_order(st["row"], [p[0]] + five)[0] == p[0], st["row"])
    t.ok("menu: one step to undo", st["canUndo"], st)
    st = cmd_z()
    t.ok("⌘Z: all five back where they were", snap(st) == snap(before), (snap(before), snap(st)))
    t.ok("⌘Z: nothing more to undo", not st["canUndo"], st)

    pick(*five)
    st = pk("folder", name="Docs", via="drag", id=p[5])
    t.ok("drag of one: all five in Docs", all(st["folderOf"][x] == "Docs" for x in five), st["folderOf"])
    t.ok("drag: in the order they had", in_order(st["row"], five) == order, (order, st["row"]))
    st = pk("folder", name="Docs", via="drag", id=p[2], anchor=p[3])
    t.ok("drag before Docs's own pin: the five before it", in_order(st["row"], five + [p[3]]) == order + [p[3]], st["row"])
    st = cmd_z()
    st = cmd_z()
    t.ok("⌘Z undoes the last move only (drag), not the one before", all(st["folderOf"][x] == "Docs" for x in five), st["folderOf"])

    pick(*five)
    st = pk("newFolder", name="Fresh")
    t.ok("New Folder with 5 Pins: all five in it", all(st["folderOf"][x] == "Fresh" for x in five), st["folderOf"])
    t.ok("…in their order", in_order(st["row"], five) == order, st["row"])
    st = pk("undo")
    t.ok("undo: the new folder goes, the five back in Docs", "Fresh" not in st["folders"]
         and all(st["folderOf"][x] == "Docs" for x in five), (st["folders"], st["folderOf"]))

    # Not picked: a drag still moves only the one carried.
    sv.cmd({"do": "split", "action": "select", "id": front}); sv.cmd({"do": "split", "action": "pick", "ids": []})
    st = pk("folder", name="Work", via="drag", id=p[1])
    t.ok("nothing picked: a drag moves just that pin", st["folderOf"][p[1]] == "Work"
         and all(st["folderOf"][x] == "Docs" for x in five[1:]), st["folderOf"])
    # A key between the move and ⌘Z: ⌘Z is the page's again.
    sv.cmd({"do": "keyeq", "code": 7, "chars": "x"}); time.sleep(0.3)
    st = cmd_z()
    t.ok("a key pressed since: ⌘Z leaves the move", st["folderOf"][p[1]] == "Work", st["folderOf"])


def case_group(t):
    """five tabs into a group, by the menu and by a drag, and back with ⌘Z"""
    sv.setup(sidebar=True, **{"tabs.groups": True, "tabs.undoReopens": True}); sv.launch()
    g = [sv.page(f"g{n}") for n in range(1, 9)]
    sv.cmd({"do": "group", "id": g[0], "new": True, "name": "Work"})
    sv.cmd({"do": "group", "id": g[7], "new": True, "name": "Other"})
    sv.sp("select", id=g[3])
    five = [g[1], g[2], g[4], g[5], g[6]]
    st = pick(*five)
    t.ok("pick: five tabs", sorted(st["selected"]) == sorted(five), st["selected"])
    before = pk("state")
    order = in_order(before["row"], five)

    st = pk("group", name="Work", via="menu")
    t.ok("menu: all five in Work", all(st["groupOf"][x] == "Work" for x in five), st["groupOf"])
    t.ok("menu: in their order, after Work's own", in_order(st["row"], [g[0]] + five) == [g[0]] + order, st["row"])
    st = cmd_z()
    t.ok("⌘Z: all five back where they were", snap(st) == snap(before), (snap(before), snap(st)))
    t.ok("⌘Z: nothing more to undo", not st["canUndo"], st)

    pick(*five)
    st = pk("group", name="Other", via="drag", id=g[4], member=g[7], after=False)
    t.ok("drag: one step to undo", st["canUndo"], st)
    t.ok("drag of one: all five in Other", all(st["groupOf"][x] == "Other" for x in five), st["groupOf"])
    t.ok("drag: before Other's tab, in their order", in_order(st["row"], five + [g[7]]) == order + [g[7]], st["row"])
    st = pk("undo")
    t.ok("undo: all five back", snap(st) == snap(before), (snap(before), snap(st)))

    pick(*five)
    st = pk("group", new=True, name="Fresh")
    t.ok("New Group: all five in it", all(st["groupOf"][x] == "Fresh" for x in five), st["groupOf"])
    t.ok("New Group: in their order", in_order(st["row"], five) == order, st["row"])
    st = cmd_z()
    t.ok("⌘Z: the new group goes, the five back", snap(st) == snap(before), (snap(before), snap(st)))

    pick(*five)
    pk("group", name="Work", via="menu")
    st = pk("group", name="none", via="menu")
    t.ok("Remove from Group: all five out", all(st["groupOf"][x] == "" for x in five), st["groupOf"])
    st = cmd_z()
    t.ok("⌘Z: back in Work", all(st["groupOf"][x] == "Work" for x in five), st["groupOf"])


def main():
    for case in [case_folder, case_group]:
        print(f"— {case.__doc__}")
        try:
            case(t)
        except Exception as error:
            t.ok(f"{case.__name__} ran to the end", False, error)
        finally:
            sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
