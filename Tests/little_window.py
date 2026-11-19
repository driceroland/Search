#!/usr/bin/env python3
"""A link's small window (Little.swift), in a hidden probe: its keys, and a
launch made by its link with several windows saved.

Build first (`./build.sh`), then `python3 Tests/little_window.py`. It uses the
split suite's harness in a world of its own (little-tests): started hidden,
no window shown, everything removed afterwards. Small windows are made unseen
by the bench, and keys are pressed on them through the app's own event queue
(`press` with "little"), so they meet the same monitors a real press does.

A test run takes no links from outside, so a launch made by a link is a
launch handed SEARCH_LINK, taken where the Apple Event would be.

Keys are pressed where this Mac's keyboard layout has them (keyboard.py):
Search reads a shortcut from the key, so the US key's code for ⌘= is ⌘- on
a French keyboard. A check whose key the layout types only with ⇧ or ⌥
([ and ] on AZERTY) is skipped, and says so.

Copying writes the Mac's pasteboard; the text on it before is put back.
"""
import json
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402
import keyboard  # noqa: E402

sv.use("little-tests")
t = sv.T()


class Editor(BaseHTTPRequestHandler):
    """A page that uses ⌘[ itself, as an editor's outdent does."""
    PAGE = (b"<!doctype html><title>editor</title><textarea id=e></textarea><script>"
            b"window.outdents = 0; document.addEventListener('keydown', function (e) {"
            b" if (e.metaKey && e.key === '[') { e.preventDefault(); window.outdents++ } })</script>")

    def do_GET(self):
        self.send_response(200); self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(Editor.PAGE))); self.end_headers(); self.wfile.write(Editor.PAGE)

    def log_message(self, *a): pass


editor = ThreadingHTTPServer(("127.0.0.1", 0), Editor)
threading.Thread(target=editor.serve_forever, daemon=True).start()
EDITOR = f"http://127.0.0.1:{editor.server_port}/editor"


def little(what): return sv.cmd({"do": "little", "what": what})
def press(code, chars, *mods): sv.cmd({"do": "press", "code": code, "chars": chars, "mods": list(mods), "little": True}); time.sleep(0.3)
def typed(chars, *mods):
    """Press the key that types chars on this Mac's layout (keyboard.py):
    the US key's code on a French keyboard is another key. False, pressing
    nothing, where no key types it without ⇧ or ⌥."""
    code = keyboard.code(chars)
    if code is None: return False
    press(code, chars, *mods); return True
def key_in_little(chars):
    code = keyboard.code(chars)
    if code is not None: sv.cmd({"do": "little", "what": "key", "chars": chars, "code": code})
    return code is not None
def unpressable(chars, checks):
    print(f"  skip  {checks}: no key types {chars} on this keyboard layout")
def paste(): return subprocess.run(["pbpaste"], capture_output=True, text=True).stdout
def windows(**f): return sv.cmd({"do": "windows", **f})
def records(): return json.load(open(f"{sv.SUPPORT}/windows.json"))
def real(url):
    """A tab as a person opens one: a bench tab is never written down."""
    before = {x["id"] for x in sv.cmd({"do": "tabs"})["tabs"]}
    sv.cmd({"do": "ui", "show": url})
    for _ in range(50):
        new = [x["id"] for x in sv.cmd({"do": "tabs"})["tabs"] if x["id"] not in before]
        if new: return new[0]
        time.sleep(0.1)
    raise RuntimeError(f"no tab for {url}")
def until(check, seconds=5):
    for _ in range(int(seconds * 10)):
        if check(): return True
        time.sleep(0.1)
    return False
def front_url(): return next((x["url"] for x in sv.cmd({"do": "tabs"})["tabs"] if x["active"]), "")
def kept_rows(): return [u for r in records()[1:] for shape in r.get("rows", {}).values() for u in json.dumps(shape).split('"') if u.startswith(sv.BASE)]


def launch_with(link):
    """sv.launch, handed a link to launch with."""
    if os.path.exists(sv.SOCK): os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={sv.W}", "--env", f"SEARCH_LINK={link}", sv.APP])
    for _ in range(150):
        if os.path.exists(sv.SOCK): break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update((sv.running() - before) & sv.holding())


saved = subprocess.run(["pbpaste"], capture_output=True).stdout
try:
    sv.setup(); sv.launch()

    # Small windows off, as they are unless turned on: no Open in Small
    # Window in the Tabs menu (nor in a tab's menu, built the same way).
    def tabs_menu(): return sv.cmd({"do": "menus"})["menus"].get("Tabs", [])
    t.ok("small windows off: no Open in Small Window in the Tabs menu",
         "Open in Small Window" not in tabs_menu() and "Duplicate Tab" in tabs_menu(), tabs_menu())

    # A tab already in the row, lifted into a small window, then kept back.
    page = f"{sv.BASE}/aside"
    opened = sv.cmd({"do": "open", "url": page})
    time.sleep(1.5)
    st = sv.cmd({"do": "little", "what": "lift", "id": opened["id"]})
    t.ok("a tab opens in a small window", page in st["littles"], st)
    row = sv.cmd({"do": "tabs"})["tabs"]
    t.ok("and leaves the row", all(page not in (item.get("url"), item.get("page"), item.get("view")) for item in row), row)
    sv.cmd({"do": "little", "what": "keep"})
    time.sleep(0.5)
    st = little("look")
    row = sv.cmd({"do": "tabs"})["tabs"]
    back = next((item for item in row if page in (item.get("url"), item.get("page"), item.get("view"))), None)
    t.ok("Open in Search puts it back in the row", st["littles"] == [] and back is not None, (st["littles"], row))
    if back: sv.cmd({"do": "close", "id": back["id"]})

    # ⌘⇧C: this page's address, said at the window's foot — not the tab
    # behind it in the browser's window, which the menu would copy.
    little(f"{sv.BASE}/copied"); time.sleep(2)
    subprocess.run(["pbcopy"], input=b"before")
    typed("c", "cmd", "shift")
    t.ok("⌘⇧C copies the small window's address", paste() == f"{sv.BASE}/copied", paste())
    t.ok("⌘⇧C says so in the small window", little("look")["said"] == "Address copied", little("look"))
    time.sleep(2)
    t.ok("and then stops saying it", little("look")["said"] == "")

    # Zoom: its page, by the browser's steps, said at its own foot.
    typed("=", "cmd")
    st = little("look")
    t.ok("⌘+ zooms the small window's page", abs(st["zoom"] - 1.1) < 0.01, st["zoom"])
    t.ok("and says so there", st["said"] == "110%", st["said"])
    typed("-", "cmd"); typed("-", "cmd")
    t.ok("⌘- zooms it out", little("look")["zoom"] < 1, little("look")["zoom"])
    press(29, "0", "cmd")
    t.ok("⌘0 puts it back", abs(little("look")["zoom"] - 1) < 0.01, little("look")["zoom"])

    # Back stays in this window, and previous/next tab walk the small
    # windows. Neither changes the tab in the window behind, which has a
    # page to go back to and a second tab to go to, so either would show.
    sv.cmd({"do": "ui", "go": f"{sv.BASE}/behind-one"}); until(lambda: front_url().endswith("/behind-one"))
    sv.cmd({"do": "ui", "go": f"{sv.BASE}/behind-two"}); until(lambda: front_url().endswith("/behind-two"))
    sv.cmd({"do": "open", "url": f"{sv.BASE}/row-second"}); time.sleep(0.5)
    active = little("look")["activeID"]
    t.ok("the row behind has two tabs", len(sv.cmd({"do": "tabs"})["tabs"]) >= 2, sv.cmd({"do": "tabs"}))
    if typed("]", "cmd", "shift"):
        t.ok("one small window: next tab keeps the row's tab", little("look")["activeID"] == active, little("look"))
    else: unpressable("]", "next tab with one small window")
    sv.cmd({"do": "little", "what": "go", "url": f"{sv.BASE}/onward"}); time.sleep(1.5)
    t.ok("the small window went on to another page", little("look")["littles"][-1].endswith("/onward"), little("look"))
    if typed("[", "cmd"):
        time.sleep(0.6)
        st = little("look")
        t.ok("⌘[ goes back in the small window", st["littles"][-1].endswith("/copied"), st)
        t.ok("⌘[ keeps the browser's tab on its page", st["activeID"] == active and front_url().endswith("/behind-two"), (st, front_url()))
    else: unpressable("[", "⌘[ back in the small window")
    if keyboard.code("[") is not None and keyboard.code("]") is not None:
        # A page that uses ⌘[ itself gets it first, as in the browser's window:
        # the editor outdents, and the small window doesn't go back.
        sv.cmd({"do": "little", "what": "go", "url": EDITOR})
        def editor_ready(): return sv.cmd({"do": "little", "what": "js", "js": "!!document.getElementById('e')"}).get("value") is True
        t.ok("the small window went on to an editor", until(editor_ready), little("look"))
        def outdents(): return sv.cmd({"do": "little", "what": "js", "js": "window.outdents"}).get("value")
        sv.cmd({"do": "little", "what": "js", "js": "document.getElementById('e').focus(); 0"})
        key_in_little("[")
        t.ok("⌘[ in an editor is the editor's", until(lambda: outdents() == 1), outdents())
        time.sleep(0.5)
        t.ok("and the small window stays on its page", little("look")["pages"][-1] == EDITOR, little("look")["pages"])
        # On a page with no use for it, the same key comes back unused: Back.
        sv.cmd({"do": "little", "what": "go", "url": f"{sv.BASE}/plain"})
        until(lambda: sv.cmd({"do": "little", "what": "js", "js": "location.pathname == '/plain' && document.readyState == 'complete'"}).get("value") is True)
        key_in_little("[")
        t.ok("⌘[ a page leaves unused is Back", until(lambda: little("look")["pages"][-1] == EDITOR), little("look")["pages"])
        def loaded(path): return sv.cmd({"do": "little", "what": "js", "js": f"location.pathname == '{path}' && document.readyState == 'complete'"}).get("value") is True
        sv.cmd({"do": "little", "what": "js", "js": "document.activeElement.blur(); 0"})
        key_in_little("]")
        t.ok("⌘] a page leaves unused is Forward", until(lambda: loaded("/plain")), little("look")["pages"])
        # Pressed twice before WebKit answers the first: both stay this
        # window's, and the browser's tab stays where it was. (WebKit takes two
        # Backs that close together as one.)
        sv.cmd({"do": "little", "what": "go", "url": f"{sv.BASE}/plain-two"}); until(lambda: loaded("/plain-two"))
        key_in_little("[")
        key_in_little("[")
        t.ok("⌘[ twice quickly goes back here", until(lambda: not little("look")["pages"][-1].endswith("/plain-two")), little("look")["pages"])
        t.ok("and keeps the browser's tab on its page", front_url().endswith("/behind-two"), front_url())
    else: unpressable("[ or ]", "⌘[ and ⌘] in a page")

    # Three small windows: next and previous go round them in the order
    # they were opened, from the newest, which has the keys.
    little(f"{sv.BASE}/second"); time.sleep(1.2)
    little(f"{sv.BASE}/third"); time.sleep(1.2)
    first = little("look")["littles"][0]
    if typed("]", "cmd", "shift"):
        st = little("look")
        t.ok("⇧⌘] from the newest goes round to the first", st["fronted"] == first, st)
        t.ok("⇧⌘] keeps the browser's tab", st["activeID"] == active, st)
    else: unpressable("]", "⇧⌘] round the small windows")
    if typed("[", "cmd", "shift"):
        t.ok("⇧⌘[ goes the other way, to the one before", little("look")["fronted"].endswith("/second"), little("look"))
    else: unpressable("[", "⇧⌘[ round the small windows")
    for _ in range(3): little("close"); time.sleep(0.3)

    # ⌘W and Escape close it; the browser's row is as it was.
    little(f"{sv.BASE}/closing"); time.sleep(1.2)
    tabs = little("look")["tabs"]
    typed("w", "cmd")
    st = little("look")
    t.ok("⌘W closes the small window", st["littles"] == [], st["littles"])
    t.ok("⌘W leaves the browser's tabs alone", st["tabs"] == tabs, (tabs, st["tabs"]))
    little(f"{sv.BASE}/escaped"); time.sleep(1.5)
    press(53, "\u001b")
    t.ok("Escape closes it", little("look")["littles"] == [])

    # Kept: into the row, the small window gone.
    little(f"{sv.BASE}/kept"); time.sleep(1.5)
    little("keep"); time.sleep(0.5)
    st = little("look")
    t.ok("Open in Search moves the page into the row", "127.0.0.1" in st["tabs"] and st["littles"] == [], st)

    # Three windows, each with a page, written down; then a launch made by a
    # small window's link. Every window stays, off screen, and nothing is
    # written out of windows.json — before Open in Search, through a quit
    # without it, and after it.
    for n, name in [(2, "two"), (3, "three")]:
        windows(action="new"); windows(action="front", n=n)
        windows(action="link", url=f"{sv.BASE}/{name}"); time.sleep(1)
    windows(action="front", n=1)
    st = windows()
    t.ok("three windows, each with its page", len(st["windows"]) == 3
         and any(f"{sv.BASE}/two" in w["tabs"] for w in st["windows"])
         and any(f"{sv.BASE}/three" in w["tabs"] for w in st["windows"]), st["windows"])
    sv.quit()
    t.ok("windows.json has all three", len(records()) == 3 and {f"{sv.BASE}/two", f"{sv.BASE}/three"} <= set(kept_rows()), records())
    subprocess.run(["defaults", "write", sv.SUITE, "links.little", "-bool", "true"])

    launch_with(f"{sv.BASE}/linked")
    st = windows()
    t.ok("the link's small window", st["littles"] == [f"{sv.BASE}/linked"], st["littles"])
    t.ok("the browser's windows kept away", st["keptAway"] and all(w["away"] for w in st["windows"]), st["windows"])
    t.ok("none of them closed", not st["closedWindows"], st)
    sv.quit()
    t.ok("quit without them: windows.json still has all three",
         len(records()) == 3 and {f"{sv.BASE}/two", f"{sv.BASE}/three"} <= set(kept_rows()), records())

    launch_with(f"{sv.BASE}/linked")
    little("keep"); time.sleep(1)
    st = windows()
    t.ok("Open in Search brings them all back", not st["keptAway"] and len(st["windows"]) == 3
         and not any(w["away"] for w in st["windows"]), st["windows"])
    t.ok("with the page in the row", any(f"{sv.BASE}/linked" in w["tabs"] for w in st["windows"]), st["windows"])
    sv.quit()
    subprocess.run(["defaults", "write", sv.SUITE, "links.little", "-bool", "false"])
    sv.launch()
    st = windows()
    t.ok("a plain launch after: all three windows, their pages", len(st["windows"]) == 3
         and any(f"{sv.BASE}/two" in w["tabs"] for w in st["windows"])
         and any(f"{sv.BASE}/three" in w["tabs"] for w in st["windows"]), st["windows"])

    # Go to a tab that has the page: off, a link to a page open in a tab
    # still gets a small window of its own.
    def tabs(): return sv.cmd({"do": "tabs"})["tabs"]
    def active(): return next((x["url"] for x in tabs() if x["active"]), "")
    opened = f"{sv.BASE}/open"
    sv.setup(**{"links.little": True}); sv.launch()
    t.ok("small windows on: Open in Small Window in the Tabs menu", "Open in Small Window" in tabs_menu(), tabs_menu())
    sv.cmd({"do": "open", "url": opened}); time.sleep(1.5)
    windows(action="link", url=opened); time.sleep(0.5)
    t.ok("off: a link to an open page gets a small window", little("look")["littles"] == [opened], little("look"))

    # On: that link goes to its tab, and a page open nowhere still gets a
    # small window, which the same link again brings forward.
    sv.setup(**{"links.little": True, "links.little.tabs": True}); sv.launch()
    sv.cmd({"do": "open", "url": opened}); time.sleep(1.5)
    t.ok("the page opens behind", active() != opened, tabs())
    windows(action="link", url=opened); time.sleep(0.5)
    st = little("look")
    t.ok("on: a link to an open page goes to its tab", active() == opened, tabs())
    t.ok("with no small window", st["littles"] == [], st["littles"])
    elsewhere = f"{sv.BASE}/elsewhere"
    windows(action="link", url=elsewhere); time.sleep(1.5)
    t.ok("a page open nowhere still gets a small window", little("look")["littles"] == [elsewhere], little("look"))
    windows(action="link", url=elsewhere); time.sleep(0.5)
    st = little("look")
    t.ok("the same link again brings that small window, not a second",
         st["littles"] == [elsewhere] and st["fronted"] == elsewhere, st)

    # A tab lifted from a space that is then only on disk: closing its small
    # window takes that tab's entry out of the space's file, and not a tab
    # with the same address left in the row there (Browser.dropLifted).
    def entries(space): return [e for e in sv.session(space)["tabs"] if e["url"].startswith(sv.BASE)]
    def twins(space): return [e for e in entries(space) if e["url"] == twin]
    sv.setup(**{"spaces": True, "links.little": True}); sv.launch()
    sv.cmd({"do": "space", "action": "new", "name": "Two"}); time.sleep(0.5)
    sv.cmd({"do": "space", "action": "go", "index": 2}); time.sleep(0.8)
    two = next(x["id"] for x in sv.cmd({"do": "space"})["spaces"] if x["name"] == "Two")
    twin = f"{sv.BASE}/twin"
    first = real(twin)
    second = real(twin)
    real(f"{sv.BASE}/third"); time.sleep(1.5)
    sv.cmd({"do": "select", "id": first}); time.sleep(0.3)
    sv.cmd({"do": "little", "what": "lift", "id": second}); time.sleep(0.5)
    t.ok("lifted: the space's file has both twins, one marked as lifted",
         len(twins(two)) == 2 and sum(1 for e in twins(two) if e.get("lifted")) == 1, entries(two))
    sv.cmd({"do": "ui", "spaces": False}); time.sleep(1)
    t.ok("spaces off: that space is only on disk now", sv.cmd({"do": "space"})["parked"] == [], sv.cmd({"do": "space"}))
    little("close"); time.sleep(0.8)
    left = twins(two)
    t.ok("closing the small window takes out the lifted twin only",
         len(left) == 1 and not left[0].get("lifted"), entries(two))
    t.ok("the rest of that space's row is as it was", [e["url"] for e in entries(two)] == [twin, f"{sv.BASE}/third"], entries(two))

    # Kept from another space: Open in Search puts it in the row on screen,
    # and the space it came from forgets it, so a relaunch doesn't bring it
    # back in both.
    sv.cmd({"do": "ui", "spaces": True}); time.sleep(0.5)
    sv.cmd({"do": "space", "action": "go", "index": 2}); time.sleep(0.8)
    lone = f"{sv.BASE}/lone"
    lifted = real(lone); time.sleep(1.5)
    sv.cmd({"do": "little", "what": "lift", "id": lifted}); time.sleep(0.5)
    sv.cmd({"do": "space", "action": "go", "index": 1}); time.sleep(0.8)
    t.ok("parked: the space it came from still writes it down",
         any(e["url"] == lone and e.get("lifted") for e in entries(two)), entries(two))
    little("keep"); time.sleep(0.8)
    row = [x.get("url") for x in sv.cmd({"do": "tabs"})["tabs"]]
    t.ok("kept: in the row of the space on screen", lone in row, row)
    t.ok("and out of the file of the space it came from", all(e["url"] != lone for e in entries(two)), entries(two))

    # Lifted from a space that is then loaded from disk again: the row
    # doesn't make a second tab of it while it is in its small window.
    sv.cmd({"do": "space", "action": "go", "index": 2}); time.sleep(0.8)
    dup = f"{sv.BASE}/once"
    once = real(dup); time.sleep(1.2)
    sv.cmd({"do": "little", "what": "lift", "id": once}); time.sleep(0.5)
    sv.cmd({"do": "ui", "spaces": False}); time.sleep(0.8)
    sv.cmd({"do": "ui", "spaces": True}); time.sleep(0.5)
    sv.cmd({"do": "space", "action": "go", "index": 2}); time.sleep(1)
    row = [x.get("url") for x in sv.cmd({"do": "tabs"})["tabs"]]
    t.ok("its space loaded again: not in the row while it is out", dup not in row, row)
    little("keep"); time.sleep(0.8)
    row = [x.get("url") for x in sv.cmd({"do": "tabs"})["tabs"]]
    t.ok("kept: in the row once", row.count(dup) == 1, row)

    # A lifted tab is yours: Escape is the page's, and closed it comes back
    # with ⇧⌘T.
    gone = f"{sv.BASE}/reopened"
    lifted = real(gone); time.sleep(1.2)
    sv.cmd({"do": "little", "what": "lift", "id": lifted}); time.sleep(0.5)
    press(53, "\x1b")
    t.ok("Escape leaves a lifted tab's window open", little("look")["littles"] == [gone], little("look"))
    typed("w", "cmd")
    t.ok("⌘W closes it", until(lambda: little("look")["littles"] == []), little("look"))
    sv.cmd({"do": "press", "code": 17, "chars": "t", "mods": ["cmd", "shift"]})
    t.ok("⇧⌘T brings it back in the row", until(lambda: gone in [x.get("url") for x in sv.cmd({"do": "tabs"})["tabs"]]),
         sv.cmd({"do": "tabs"}))

    # A quit with a tab lifted: the relaunch has it in its row again.
    sv.cmd({"do": "space", "action": "go", "index": 2}); time.sleep(0.8)
    back = real(f"{sv.BASE}/comeback"); time.sleep(1.5)
    sv.cmd({"do": "little", "what": "lift", "id": back}); time.sleep(0.5)
    sv.quit(); sv.launch()
    sv.cmd({"do": "space", "action": "go", "index": 2}); time.sleep(1)
    row = [x.get("url") for x in sv.cmd({"do": "tabs"})["tabs"]]
    t.ok("quit with a tab lifted: back in its space's row after a relaunch",
         f"{sv.BASE}/comeback" in row and little("look")["littles"] == [], row)

    # After a relaunch a tab in the background only waits to wake: lifted,
    # its page is loaded, not a blank window.
    sleepy = next((x for x in sv.cmd({"do": "tabs"})["tabs"] if x.get("url") == f"{sv.BASE}/comeback"), None)
    t.ok("the tab back from the quit is asleep", sleepy is not None and sleepy["asleep"] and not sleepy["active"], sleepy)
    if sleepy:
        sv.cmd({"do": "little", "what": "lift", "id": sleepy["id"]})
        t.ok("lifted asleep: the small window loads its page",
             until(lambda: little("look")["pages"] == [f"{sv.BASE}/comeback"], 6), little("look"))
        little("close"); time.sleep(0.3)

    # A second window's lifted tab, through a quit: a window after the
    # first keeps its rows in windows.json (Windows.save), and the page is
    # written there too. Small windows off here, so the link is a tab in
    # the window in front; the bench lifts it all the same.
    sv.setup(); sv.launch()
    windows(action="new"); windows(action="front", n=2); time.sleep(0.5)
    other = f"{sv.BASE}/second-window"
    windows(action="link", url=other)
    t.ok("the page is in the second window",
         until(lambda: other in windows()["windows"][1]["tabs"]), windows()["windows"])
    second = windows()["windows"][1]
    sv.cmd({"do": "little", "what": "lift", "id": second["ids"][second["tabs"].index(other)]}); time.sleep(0.5)
    t.ok("lifted out of the second window", other not in windows()["windows"][1]["tabs"], windows()["windows"])

    sv.quit()
    t.ok("quit: the second window's record has the lifted page", other in kept_rows(), records())
    sv.launch()
    st = windows()
    t.ok("relaunch: back in the second window's row", any(other in w["tabs"] for w in st["windows"]), st["windows"])

    # A pin is the row's, and stays there.
    pinned = real(f"{sv.BASE}/pinned"); time.sleep(0.8)
    sv.cmd({"do": "pin", "id": pinned})
    sv.cmd({"do": "little", "what": "lift", "id": pinned}); time.sleep(0.5)
    t.ok("a pin is not lifted", little("look")["littles"] == [] and pinned in [x["id"] for x in sv.cmd({"do": "tabs"})["tabs"]],
         little("look")["littles"])

    # The window it came from closes while another stays open: the other
    # keeps it, so a quit still writes it down.
    if len(windows()["windows"]) < 2: windows(action="new")
    windows(action="front", n=2); time.sleep(0.5)
    open_before = len(windows()["windows"])
    orphan = f"{sv.BASE}/orphan"
    windows(action="link", url=orphan)
    until(lambda: orphan in windows()["windows"][1]["tabs"])
    second = windows()["windows"][1]
    sv.cmd({"do": "little", "what": "lift", "id": second["ids"][second["tabs"].index(orphan)]}); time.sleep(0.5)
    windows(action="close", n=2)
    t.ok("its window closed: the small window stays",
         until(lambda: len(windows()["windows"]) == open_before - 1) and little("look")["littles"] == [orphan],
         (open_before, len(windows()["windows"]), little("look")["littles"]))
    t.ok("and the window that stayed wrote it down", orphan in json.dumps(records()) + json.dumps(sv.session()),
         (records(), sv.session()))
    sv.quit(); sv.launch()
    t.ok("after a quit, it is in the window that stayed", any(orphan in w["tabs"] for w in windows()["windows"]), windows()["windows"])

    # Its space deleted while it is out: a quit writes it into the space on
    # screen, not into a space that is gone.
    sv.setup(**{"spaces": True}); sv.launch()
    sv.cmd({"do": "space", "action": "new", "name": "Gone"}); time.sleep(0.5)
    sv.cmd({"do": "space", "action": "go", "index": 2}); time.sleep(0.8)
    stray = f"{sv.BASE}/stray"
    lifted = real(stray); time.sleep(1.2)
    sv.cmd({"do": "little", "what": "lift", "id": lifted}); time.sleep(0.5)
    sv.cmd({"do": "space", "action": "delete"}); time.sleep(1)
    t.ok("its space deleted: the small window stays", little("look")["littles"] == [stray], little("look")["littles"])
    sv.quit(); sv.launch()
    t.ok("after a quit, it is in the space on screen", stray in [x.get("url") for x in sv.cmd({"do": "tabs"})["tabs"]],
         sv.cmd({"do": "tabs"})["tabs"])

    # Back moved to ⌘← in Settings › Shortcuts: while you type in a small
    # window, ⌘← moves the caret to the start of the line, and the window
    # doesn't go back. Launched by a link, with no browser window at all.
    sv.setup(**{"links.little": True})
    arrow = {"tabs.back": {"key": {"key": "left", "command": True, "shift": False, "option": False, "control": False}}}
    subprocess.run(["defaults", "write", sv.SUITE, "shortcuts", "-data", json.dumps(arrow).encode().hex()])
    launch_with(f"{sv.BASE}/first")
    t.ok("launched by a link: a small window, no browser window",
         until(lambda: little("look")["littles"] == [f"{sv.BASE}/first"]) and windows()["keptAway"], windows())
    sv.cmd({"do": "little", "what": "go", "url": EDITOR})
    t.ok("on to the editor", until(editor_ready), little("look"))
    sv.cmd({"do": "little", "what": "js", "js": "var e = document.getElementById('e'); e.value = 'typed'; e.focus(); "
                                              "e.setSelectionRange(5, 5); 0"})
    sv.cmd({"do": "little", "what": "key", "chars": "\uf702", "code": 123})
    caret = lambda: sv.cmd({"do": "little", "what": "js", "js": "document.getElementById('e').selectionStart"}).get("value")
    t.ok("⌘← bound to Back moves the caret while typing", until(lambda: caret() == 0), caret())
    t.ok("and the small window stays on its page", little("look")["pages"] == [EDITOR], little("look")["pages"])
    sv.cmd({"do": "little", "what": "js", "js": "document.activeElement.blur(); 0"})
    sv.cmd({"do": "little", "what": "key", "chars": "\uf702", "code": 123})
    t.ok("⌘← with nothing being typed is Back", until(lambda: little("look")["pages"] == [f"{sv.BASE}/first"]), little("look")["pages"])
finally:
    subprocess.run(["pbcopy"], input=saved)
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
