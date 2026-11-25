#!/usr/bin/env python3
"""⌘Z reopens the last closed tab (Settings › Tabs), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/undo_reopens.py` from a
worktree. The keys go through the window's own key handling with the page
holding the keyboard (`keyeq`), as a hidden probe has no key window for a
posted press to reach.

Checked here: off, as it comes, ⌘Z brings nothing back. On, ⌘Z right
after a close brings that tab back, once; a key pressed or another tab
gone to in between, and it doesn't. A text box the tab landed on with its
caret in doesn't keep it, and a page that takes ⌘Z for itself does.
Not checked here: a click in between, which a hidden probe can't make
through the window's own event queue; it goes the way a key does.
"""
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("undo-reopens")


def z_key():
    """The key code that types z on this Mac's keyboard layout: Search reads
    a shortcut by what its key types (6 on QWERTY, 13 on AZERTY)."""
    js = ('ObjC.import("AppKit"); var c = -1; for (var k = 0; k < 51 && c < 0; k++) {'
          ' var e = $.NSEvent.keyEventWithTypeLocationModifierFlagsTimestampWindowNumberContextCharactersCharactersIgnoringModifiersIsARepeatKeyCode('
          '$.NSEventTypeKeyDown, $.NSMakePoint(0, 0), 0, 0, 0, $(), "x", "x", false, k);'
          ' if (ObjC.unwrap(e.charactersByApplyingModifiers(0)) === "z") c = k; } c')
    out = subprocess.run(["osascript", "-l", "JavaScript", "-e", js], capture_output=True, text=True).stdout.strip()
    return int(out) if out.lstrip("-").isdigit() and int(out) >= 0 else 6


Z = z_key()


def undo():
    a = sv.cmd({"do": "keyeq", "code": Z, "chars": "z"})
    time.sleep(1)
    return a


def gone(path="/gone"):
    return [x["id"] for x in sv.sp("state")["tabs"] if x["url"].endswith(path)]


def close_one(keep, name="gone"):
    """Opens a page, goes back to `keep`, and closes the page from there."""
    page = sv.page(name)
    sv.sp("select", id=keep); time.sleep(0.4)
    sv.sp("close", id=page); time.sleep(0.5)
    return page


def tidy():
    for id in gone():
        sv.sp("close", id=id); time.sleep(0.3)


def main():
    t = sv.T()
    try:
        # Turned off (on by default since 25 Nov 2026).
        sv.setup(**{"tabs.undoReopens": False}); sv.launch()
        keep = sv.page("keep")
        close_one(keep)
        a = undo()
        t.ok("off: ⌘Z leaves the tab closed", not gone(), (a, gone()))
        sv.quit()

        sv.setup(**{"tabs.undoReopens": True}); sv.launch()
        keep = sv.page("keep")
        other = sv.page("other")
        sv.sp("select", id=keep); time.sleep(0.4)

        close_one(keep)
        a = undo()
        t.ok("on: ⌘Z right after the close brings the tab back", len(gone()) == 1, (a, gone()))
        t.ok("…and in front", sv.sp("state")["activeID"] in gone(), sv.sp("state")["activeID"])
        sv.sp("select", id=keep); time.sleep(0.4)
        tidy()

        # Two closed, ⌘Z twice: only the last comes back.
        sv.sp("select", id=keep); time.sleep(0.4)
        close_one(keep, "gone-first"); close_one(keep)
        undo(); undo()
        t.ok("on: ⌘Z twice brings back the last close only", len(gone()) == 1 and not gone("/gone-first"),
             (gone(), gone("/gone-first")))
        sv.sp("select", id=keep); time.sleep(0.4)
        tidy()

        # A key pressed after the close: no longer the last thing done.
        close_one(keep)
        sv.cmd({"do": "keyeq", "code": 7, "chars": "x"}); time.sleep(0.6)
        a = undo()
        t.ok("on: a key in between, ⌘Z leaves it closed", not gone(), (a, gone()))

        # Another tab gone to after the close.
        close_one(keep)
        sv.sp("select", id=other); time.sleep(0.4)
        a = undo()
        t.ok("on: another tab gone to in between, ⌘Z leaves it closed", not gone(), (a, gone()))

        # Landed on a text box with its caret in: nothing typed there yet.
        sv.sp("select", id=keep); time.sleep(0.4)
        sv.ev(keep, "document.body.innerHTML = '<input id=i>'; document.getElementById('i').focus(); true")
        time.sleep(0.4)
        close_one(keep)
        a = undo()
        t.ok("on: a caret in a text box doesn't keep ⌘Z from the close", len(gone()) == 1, (a, gone()))
        sv.sp("select", id=keep); time.sleep(0.4)
        tidy()

        # A page with its own undo, a drawing or a document, keeps the key.
        sv.sp("select", id=keep); time.sleep(0.4)
        sv.ev(keep, "document.activeElement.blur(); document.body.innerHTML = '<p>canvas</p>';"
                    " addEventListener('keydown', e => { if (e.metaKey && e.key === 'z') e.preventDefault(); }); true")
        time.sleep(0.4)
        close_one(keep)
        a = undo()
        t.ok("on: a page that takes ⌘Z keeps it", not gone() and a.get("firstPass") == "page", (a, gone()))
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
