#!/usr/bin/env python3
"""One Escape leaves a page's full screen, or two with Settings › General ›
Press Esc twice to leave full screen, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/fullscreen_escape.py`.
Nothing goes full screen: the bench's `layouts` fakes the page's own word
that it is going (Tab.immersed), the page's view is given the keys, and
Escape is pressed through the app's own event queue, so the window's key
monitor sees it first, as a real press. A video's full screen took two
presses to leave (fab, 22 Oct 2026): WebKit's full-screen window isn't a
browser's, its keys went to the browser in front, and Escape there put
away what was left up behind the video, the find bar or the address
field, before the page had it. Checked here, with the switch off: with a
page filling the screen, the first Escape reaches the page and leaves the
find bar, the field and a peek where they are, alone or in a pair, with
the page's own Escape listener on it too, and no reminder comes up; a key
the page doesn't use is still kept quiet (#402); and with no page filling
the screen, Escape still puts those away.

With the switch on, as in Arc (fab, 22 Oct 2026): the first Escape is
kept from the page, its key-up too, and the reminder is up (the probe's
escapeReminder; a test run keeps the pill itself off every screen); a
second within two seconds reaches the page and takes the reminder away;
a key the page doesn't use is still kept quiet (#402); a ⌃Tab switcher
left up goes at the first press, which is still kept; Escape held down
never reaches the page, however long, and the press after letting go is
the second; once the two seconds are over the next Escape is a first
again; the page leaving full screen by itself takes the reminder away;
with no page filling the screen, Escape closes the find bar at the
first press; and a first press in one window is never the second of
one in another. Alone and in either pane of a pair. WebKit's own part,
the video leaving on that key, and the pill as it shows over a real full
screen, are checked by hand on a release candidate.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("fullscreen-escape")
ESC = "\u001b"
CMD_L = 37

# Every key the page sees; "keep" makes it the page's own Escape listener,
# which takes the key for itself as a player's does.
LISTEN = """
window.__keys = [];
if (!window.__listening) {
  window.__listening = true;
  ['keydown', 'keyup'].forEach(function (type) {
    window.addEventListener(type, function (e) {
      window.__keys.push(type + ':' + e.key);
      if (window.__keep && e.key === 'Escape') e.preventDefault();
    }, true);
  });
}
window.__keep = KEEP;
1
"""


def listen(tab, keep=False):
    sv.ev(tab, LISTEN.replace("KEEP", "true" if keep else "false"))


def saw(tab):
    """What the page saw since last asked."""
    keys = sv.ev(tab, "JSON.stringify(window.__keys)")
    sv.ev(tab, "window.__keys = []; 1")
    return keys or ""


def keys_to(tab):
    """The page's view has the keys, as a click on the video leaves them;
    an x it doesn't use, so the page sees nothing to remember."""
    return sv.cmd({"do": "key", "id": tab, "text": "x"})


def esc(held=False):
    """Escape pressed through the app's queue; held, the press a key held
    down sends again and again."""
    sv.cmd({"do": "press", "code": 53, "chars": ESC, "mods": ["repeat"] if held else []}); time.sleep(0.4)


def immerse(tab, on):
    sv.cmd({"do": "layouts", "id": tab, "immerse": on, "seconds": 0.6})


def state():
    p = sv.cmd({"do": "probe"}); st = sv.sp("state")
    return {"finding": st["finding"], "field": p["field"], "peek": p["peek"],
            "quieted": p["keysQuieted"], "responder": p["responder"],
            "reminder": p.get("escapeReminder")}


def find_bar():
    sv.cmd({"do": "find", "text": "a"})


def run(t, name, split):
    sv.setup(**{"sidebar": True, "splitView": split, "fullscreen.escapeTwice": False}); sv.launch()
    a = sv.page("a")
    if split:
        b = sv.page("b")
        sv.sp("pair", id=b, **{"with": a}, side="right"); time.sleep(0.8)
        sv.sp("focus", id=a); time.sleep(0.4)
    time.sleep(0.6)
    listen(a)

    # Not filling the screen: Escape is the window's, as before.
    find_bar(); keys_to(a); saw(a)
    esc(); s = state()
    t.ok(f"{name}: no full screen, Escape closes the find bar", not s["finding"], s)
    t.ok(f"{name}: no full screen, the page doesn't see that Escape", "keydown:Escape" not in saw(a), s)

    immerse(a, True)
    # The find bar left up behind the video.
    find_bar(); keys_to(a); saw(a)
    before = state()
    esc(); s = state()
    seen = saw(a)
    t.ok(f"{name}: full screen, the first Escape reaches the page", "keydown:Escape" in seen, (seen, s))
    t.ok(f"{name}: full screen, the find bar behind stays", s["finding"], s)
    t.ok(f"{name}: full screen, with Esc twice off no reminder comes up", s["reminder"] is False, s)
    t.ok(f"{name}: full screen, nothing comes back to be kept quiet", s["quieted"] == before["quieted"], (before, s))

    # The page's own Escape listener, taking the key: still the page's.
    listen(a, keep=True)
    find_bar(); keys_to(a); saw(a)
    esc(); s = state()
    seen = saw(a)
    t.ok(f"{name}: with the page's own Escape listener, the first Escape reaches it", "keydown:Escape" in seen, (seen, s))
    t.ok(f"{name}: with the page's own Escape listener, the find bar stays", s["finding"], s)
    listen(a)

    # A key the page doesn't use is still kept quiet, full screen or not.
    quiet = keys_to(a)
    t.ok(f"{name}: full screen, a key the page doesn't use is kept quiet (#402)",
         quiet.get("sentBackUnused") == 1 and quiet.get("quieted") == 1, quiet)

    # The address field left up behind the video.
    sv.cmd({"do": "press", "code": CMD_L, "chars": "l", "mods": ["cmd"]}); time.sleep(0.5)
    up = state()["field"]
    keys_to(a); saw(a)
    s = state()
    if up and s["field"]:
        esc(); s = state()
        seen = saw(a)
        t.ok(f"{name}: full screen, the first Escape reaches the page, not the field behind", "keydown:Escape" in seen and s["field"], (seen, s))
    else:
        print(f"  --  {name}: the field didn't stay up behind the page here; not checked", up, s)
    if s["field"]:
        sv.cmd({"do": "suggest", "action": "esc"}); time.sleep(0.3)

    # A peek left up over the tab.
    if not split:
        sv.cmd({"do": "peek", "url": f"{sv.BASE}/peeked"}); time.sleep(1.0)
        keys_to(a); saw(a)
        esc(); s = state()
        seen = saw(a)
        t.ok(f"{name}: full screen, the first Escape reaches the page, and the peek stays", "keydown:Escape" in seen and s["peek"] != "", (seen, s))
        sv.cmd({"do": "peek", "url": "close"}); time.sleep(0.4)

    # Back from full screen, Escape is the window's again.
    immerse(a, False)
    find_bar(); keys_to(a); saw(a)
    esc(); s = state()
    t.ok(f"{name}: back from full screen, Escape closes the find bar", not s["finding"], s)
    t.ok(f"{name}: back from full screen, the page doesn't see that Escape", "keydown:Escape" not in saw(a), s)

    if split:
        # The other pane of the pair filling the screen.
        sv.sp("focus", id=b); time.sleep(0.4)
        listen(b)
        immerse(b, True)
        find_bar(); keys_to(b); saw(b)
        esc(); s = state()
        seen = saw(b)
        t.ok(f"{name}: the right pane full screen, the first Escape reaches it", "keydown:Escape" in seen and s["finding"], (seen, s))
        immerse(b, False)
    sv.quit()


def twice(t, name, a):
    """The two presses on page a, filling the screen, with the find bar left
    up behind it: the first kept and the reminder up, the second the page's
    and the reminder gone, the find bar there all along."""
    find_bar(); keys_to(a); saw(a)
    esc(); s = state()
    seen = saw(a)
    t.ok(f"{name}: the first Escape doesn't reach the page, nor its key-up, and the reminder is up",
         "keydown:Escape" not in seen and "keyup:Escape" not in seen and s["reminder"] is True, (seen, s))
    esc(); s = state()
    seen = saw(a)
    t.ok(f"{name}: a second within two seconds reaches the page, key-up and all, and the reminder is gone",
         "keydown:Escape" in seen and "keyup:Escape" in seen and s["reminder"] is False, (seen, s))
    t.ok(f"{name}: the find bar behind stays through both", s["finding"], s)


def run_twice(t, name, split):
    """Settings › General › Press Esc twice to leave full screen, on."""
    sv.setup(**{"sidebar": True, "splitView": split, "fullscreen.escapeTwice": True}); sv.launch()
    name = f"{name}, Esc twice"
    # Another tab, for a ⌃Tab switcher to show.
    other = None if split else sv.page("other")
    a = sv.page("a")
    if split:
        b = sv.page("b")
        sv.sp("pair", id=b, **{"with": a}, side="right"); time.sleep(0.8)
        sv.sp("focus", id=a); time.sleep(0.4)
    time.sleep(0.6)
    listen(a)

    # Not filling the screen: Escape is the window's, at the first press.
    find_bar(); keys_to(a); saw(a)
    esc(); s = state()
    t.ok(f"{name}: no full screen, the first Escape closes the find bar", not s["finding"], s)
    t.ok(f"{name}: no full screen, the page doesn't see it and no reminder comes up",
         "keydown:Escape" not in saw(a) and s["reminder"] is False, s)

    immerse(a, True)
    twice(t, name, a)

    # A key the page doesn't use is still kept quiet.
    quiet = keys_to(a)
    t.ok(f"{name}: full screen, a key the page doesn't use is kept quiet (#402)",
         quiet.get("sentBackUnused") == 1 and quiet.get("quieted") == 1, quiet)

    # A ⌃Tab switcher left up behind the video goes at the first press,
    # which is still kept from the page; the tab stays the one it was.
    if other:
        sv.cmd({"do": "press", "code": 48, "chars": "\t", "mods": ["ctrl"]}); time.sleep(0.8)
        up = sv.cmd({"do": "switcher"})
        saw(a)
        if up.get("visible"):
            esc(); s = state(); sw = sv.cmd({"do": "switcher"})
            seen = saw(a)
            t.ok(f"{name}: a ⌃Tab switcher goes at the first Escape, which the page doesn't see, with the reminder up",
                 not sw["visible"] and sw["active"] == a and "keydown:Escape" not in seen and s["reminder"] is True, (seen, s, sw))
            esc(); s = state()
            seen = saw(a)
            t.ok(f"{name}: after the switcher, the second Escape reaches the page",
                 "keydown:Escape" in seen and s["reminder"] is False and sv.cmd({"do": "switcher"})["active"] == a, (seen, s))
        else:
            print(f"  --  {name}: the switcher didn't come up over the page here; not checked", up)

    # Held down: never a second press, and no more time for one. Two
    # seconds from the first press the count is back to nothing.
    esc()
    for _ in range(6):
        esc(held=True)
    s = state(); seen = saw(a)
    t.ok(f"{name}: Escape held down past two seconds never reaches the page, and the reminder goes with the time",
         "keydown:Escape" not in seen and "keyup:Escape" not in seen and s["reminder"] is False, (seen, s))
    esc(); s = state()
    seen = saw(a)
    t.ok(f"{name}: the press after letting go, past two seconds, is a first again",
         "keydown:Escape" not in seen and "keyup:Escape" not in seen and s["reminder"] is True, (seen, s))
    esc(); s = state()
    seen = saw(a)
    t.ok(f"{name}: a quick press after it is the second", "keydown:Escape" in seen and s["reminder"] is False, (seen, s))
    # That second press held down: its repeats are kept, and bring nothing up.
    esc(held=True); esc(held=True); s = state()
    seen = saw(a)
    t.ok(f"{name}: the second press held down reaches the page no more, with no reminder",
         "keydown:Escape" not in seen and s["reminder"] is False, (seen, s))

    # Slow presses never add up: each, 2.3 s after the one before, is a first.
    esc(); time.sleep(1.9); esc(); s = state()
    seen = saw(a)
    t.ok(f"{name}: two presses 2.3 s apart don't leave: the second is a first again",
         "keydown:Escape" not in seen and s["reminder"] is True, (seen, s))
    esc(); s = state(); saw(a)

    # The two seconds over: the next Escape is a first again.
    esc(); s = state()
    up = s["reminder"]
    time.sleep(2.6); s = state()
    t.ok(f"{name}: two seconds on, the reminder has gone by itself", up is True and s["reminder"] is False, (up, s))
    esc(); s = state()
    seen = saw(a)
    t.ok(f"{name}: after the wait, the next Escape is kept again with the reminder up",
         "keydown:Escape" not in seen and "keyup:Escape" not in seen and s["reminder"] is True, (seen, s))

    # The page leaving full screen by itself takes the reminder with it.
    immerse(a, False); s = state()
    t.ok(f"{name}: the page leaving full screen by itself takes the reminder away", s["reminder"] is False, s)

    # Back from full screen, Escape is the window's again, at the first press.
    find_bar(); keys_to(a); saw(a)
    esc(); s = state()
    t.ok(f"{name}: back from full screen, the first Escape closes the find bar", not s["finding"], s)
    t.ok(f"{name}: back from full screen, the page doesn't see it and no reminder comes up",
         "keydown:Escape" not in saw(a) and s["reminder"] is False, s)

    if split:
        # The other pane of the pair filling the screen.
        sv.sp("focus", id=b); time.sleep(0.4)
        listen(b)
        immerse(b, True)
        twice(t, f"{name}, the right pane", b)
        immerse(b, False)
    else:
        # Two windows, each with a page filling the screen: a first press in
        # one, then one in the other while the reminder is still up, is the
        # other's first, never the second of the one before.
        two = lambda req: sv.cmd({**req, "window": 2})
        sv.cmd({"do": "windows", "action": "new"}); time.sleep(0.8)
        c = two({"do": "split", "action": "open", "url": f"{sv.BASE}/c"})["resultID"]; time.sleep(0.7)
        two({"do": "eval", "id": c, "js": LISTEN.replace("KEEP", "false")})
        two({"do": "layouts", "id": c, "immerse": True, "seconds": 0.6})
        immerse(a, True)
        keys_to(a); saw(a)
        esc()
        two({"do": "key", "id": c, "text": "x"})
        two({"do": "eval", "id": c, "js": "window.__keys = []; 1"})
        before = state()
        two({"do": "press", "code": 53, "chars": ESC, "mods": []}); time.sleep(0.4)
        s = state()
        seen = two({"do": "eval", "id": c, "js": "JSON.stringify(window.__keys)"}).get("value") or ""
        t.ok(f"{name}: a first press in one window, then one in another, is the other's first: kept, the reminder up",
             before["reminder"] is True and "keydown:Escape" not in seen and s["reminder"] is True, (before, seen, s))
        two({"do": "eval", "id": c, "js": "window.__keys = []; 1"})
        two({"do": "press", "code": 53, "chars": ESC, "mods": []}); time.sleep(0.4)
        s = state()
        seen = two({"do": "eval", "id": c, "js": "JSON.stringify(window.__keys)"}).get("value") or ""
        t.ok(f"{name}: and the other window's second reaches its page", "keydown:Escape" in seen and s["reminder"] is False, (seen, s))
        t.ok(f"{name}: the first window's page saw none of the three", "keydown:Escape" not in saw(a), s)
        two({"do": "layouts", "id": c, "immerse": False, "seconds": 0.6})
        immerse(a, False)
    sv.quit()


def main():
    t = sv.T()
    try:
        run(t, "alone", False)
        run(t, "Split View pair", True)
        run_twice(t, "alone", False)
        run_twice(t, "Split View pair", True)
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
