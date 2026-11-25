#!/usr/bin/env python3
"""What plays in another tab, at the foot of the sidebar, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/media_player.py`. It uses the
split suite's harness: started hidden, no window made or shown, everything
removed afterwards. The player is read and pressed through the bench's
`player`, as its buttons would.

NOTHING HERE MAY BE HEARD. Every sound is a tone of silence — samples all
zero, checked in the page before each play() — and every tab that plays is
muted first with its speaker (the bench's `mute`). No real media site.

On a tone the page makes itself: in the page, in a frame of its own, and
out of a script's reach — a `new Audio()` never put in the page, and an
<audio> in a closed shadow root, as music sites keep theirs (WebKit's
suspension, see Player.swift).
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# Its own world, apart from the split suite's in this checkout (see use()).
sv.use("media-player")

# Half a minute of silence (every sample 0, read back to be sure), as an
# <audio id=t> in the given document; its address kept as the window's
# __silent, the only source the guard below lets play.
MAKE = """function (doc) {
  var r = 8000, n = r * 30, b = new ArrayBuffer(44 + n * 2), d = new DataView(b);
  function s(o, t) { for (var i = 0; i < t.length; i++) d.setUint8(o + i, t.charCodeAt(i)) }
  s(0, 'RIFF'); d.setUint32(4, 36 + n * 2, true); s(8, 'WAVEfmt '); d.setUint32(16, 16, true);
  d.setUint16(20, 1, true); d.setUint16(22, 1, true); d.setUint32(24, r, true); d.setUint32(28, r * 2, true);
  d.setUint16(32, 2, true); d.setUint16(34, 16, true); s(36, 'data'); d.setUint32(40, n * 2, true);
  for (var i = 0; i < n; i++) d.setInt16(44 + i * 2, 0, true);
  for (var i = 0; i < n; i++) if (d.getInt16(44 + i * 2, true) !== 0) throw 'not silent';
  var w = doc.defaultView;
  w.__silent = URL.createObjectURL(new Blob([b], { type: 'audio/wav' }));
  var a = doc.createElement('audio'); a.id = 't'; a.src = w.__silent;
  doc.body.appendChild(a); return 1;
}"""
# Played only if its source is the silence above.
SAFE = "(function (a) { if (!a || a.src !== a.ownerDocument.defaultView.__silent) throw 'not the silent tone'; var p = a.play(); if (p && p.catch) p.catch(function () {}); return 1 })"
INNER = "document.querySelector('iframe').contentDocument"

t = sv.T()
def player(**f): return sv.cmd({"do": "player", **f})
def select(id): sv.cmd({"do": "select", "id": id}); time.sleep(1)
def tone(id, js, inner=False):
    doc = INNER if inner else "document"
    assert ".play()" not in js.replace("a.play()", ""), js
    js = js.replace("a.play()", f"{SAFE}(a)")
    return sv.ev(id, f"(function (a) {{ return {js} }})({doc}.getElementById('t'))")
def hush(id):
    """The tab's speaker off before anything in it plays."""
    m = sv.cmd({"do": "mute", "id": id})
    assert m.get("muted") is True, m
def noisy(id): return next((x["noisy"] for x in sv.cmd({"do": "tabs"})["tabs"] if x["id"] == id), False)
def sounding(id):
    """A page that plays its tone, picked so that it starts on screen."""
    select(id); sv.cmd({"do": "wait", "id": id, "seconds": 5}); hush(id)
    sv.ev(id, f"({MAKE})(document)"); tone(id, "a.play(), 1"); time.sleep(1.5)
def until(check, within=20, every=0.5):
    end = time.time() + within
    while time.time() < end:
        if check(): return True
        time.sleep(every)
    return False

try:
    # The videos stay in their tabs (see the docstring).
    sv.setup(**{"sidebar": True, "sidebar.player": True, "float.leave": False})
    sv.launch()
    a = sv.page("a")
    sounding(a)
    t.ok("playing on screen: no player", player()["tab"] == "")

    b = sv.page("b"); select(b)
    p = player()
    t.ok("playing in another tab: the player is for it", p["tab"] == a and p["noisy"] and not p["stilled"], p)

    # Its pause: the page's tone paused, and the row stays, to play again.
    player(act="still"); time.sleep(1.5)
    p = player()
    t.ok("paused from the player: it stays, paused", p["tab"] == a and p["stilled"] and not p["noisy"], p)
    t.ok("paused from the player: the page's tone is paused", tone(a, "a.paused") is True)

    # Its play: the same tone, from where it was, with its sound.
    player(act="play"); until(lambda: player()["noisy"], within=10)
    p = player()
    t.ok("played from the player: playing, nothing paused", p["tab"] == a and p["noisy"] and not p["stilled"], p)
    t.ok("played from the player: the page's tone plays", tone(a, "!a.paused && !a.muted") is True)

    # Paused and put away: gone until it plays again.
    player(act="still"); time.sleep(1.5); player(act="away"); time.sleep(1.5)
    t.ok("put away: no player", player()["tab"] == "")
    tone(a, "a.play(), 1"); time.sleep(1.5)
    t.ok("played again by the page: the player is back", player()["tab"] == a)

    # Quiet for longer than the media keys wait (MediaKeys.swift): the tone
    # is muted to give the keys back, and played from the player it is
    # heard again.
    player(act="still"); time.sleep(12)
    t.ok("paused a while: still in the row", player()["stilled"] is True)
    player(act="play"); until(lambda: player()["noisy"], within=10)
    t.ok("paused a while, played from the player: with its sound", tone(a, "!a.paused && !a.muted") is True)

    # Two playing out of sight: the newest to start.
    c = sv.page("c")
    sounding(c)
    t.ok("the other one on screen: the player is for the first", player()["tab"] == a)
    select(b)
    t.ok("two out of sight: the newest", player()["tab"] == c)
    player(act="go"); time.sleep(1)
    t.ok("a click on it: its tab is the one in front",
         any(x["id"] == c and x["active"] for x in sv.cmd({"do": "tabs"})["tabs"]))
    t.ok("a click on it: the player goes on to the other", player()["tab"] == a)
    tone(c, "a.pause(), 1"); select(b)

    # Paused from the player, then the page goes elsewhere: nothing to play.
    player(act="still"); time.sleep(1.5)
    t.ok("paused before the page goes: it stays", player()["stilled"] is True)
    sv.cmd({"do": "go", "id": a, "url": f"{sv.BASE}/elsewhere"}); time.sleep(1.5)
    t.ok("the page gone: no player", player()["tab"] == "")

    # Paused from the player, then the tab sleeps: nothing to play either.
    sv.cmd({"do": "go", "id": a, "url": f"{sv.BASE}/a"}); time.sleep(1.5)
    sounding(a); select(b)
    player(act="still"); time.sleep(1.5)
    sv.cmd({"do": "sleep", "id": a}); time.sleep(1)
    t.ok("the tab asleep: no player", player()["tab"] == "")

    # In a frame of the page's: paused and played there, the page's own
    # document having nothing.
    f = sv.page("framed"); select(f); hush(f)
    sv.ev(f, f"var e = document.createElement('iframe'); e.src = '{sv.BASE}/inner'; document.body.appendChild(e); 1"); time.sleep(2.5)
    sv.ev(f, f"({MAKE})({INNER})"); tone(f, "a.play(), 1", inner=True); time.sleep(1.5)
    select(b)
    t.ok("in a frame: the player is for its page", player()["tab"] == f)
    player(act="still"); time.sleep(1.5)
    t.ok("in a frame: paused there, and the row stays",
         tone(f, "a.paused", inner=True) is True and player()["stilled"] is True)
    player(act="play"); until(lambda: player()["noisy"], within=10)
    t.ok("in a frame: played again there", tone(f, "!a.paused && !a.muted", inner=True) is True)
    tone(f, "a.pause(), 1", inner=True); time.sleep(1)

    # Out of a script's reach, as on music sites: a `new Audio()` never put
    # in the page, then an <audio> in a closed shadow root. The player
    # pauses them through WebKit and keeps its row, with play.
    for kind, build in (("new Audio()", "window.__p = new Audio(window.__silent)"),
                        ("closed shadow root", "var h = document.createElement('div'); document.body.appendChild(h); "
                         "var r = h.attachShadow({ mode: 'closed' }); window.__p = document.createElement('audio'); "
                         "window.__p.src = window.__silent; r.appendChild(window.__p)")):
        u = sv.page("music"); select(u); sv.cmd({"do": "wait", "id": u, "seconds": 5}); hush(u)
        sv.ev(u, f"({MAKE})(document); document.getElementById('t').remove(); {build}; "
                 # One more the page paused itself before the player's pause.
                 "window.__q = new Audio(window.__silent); 1")
        def P(js): return sv.ev(u, f"(function (a, q) {{ return {js} }})(window.__p, window.__q)")
        P(f"{SAFE}(q), 1"); time.sleep(0.8); P("q.pause(), 1")
        t.ok(f"{kind}: nothing in the page a script can see", sv.ev(u, "document.querySelectorAll('audio, video').length") == 0)
        P(f"{SAFE}(a), 1")
        until(lambda: noisy(u), within=15); select(b)
        p = player()
        t.ok(f"{kind}: out of sight, the player is for it", p["tab"] == u and p["noisy"],
             (p, P("JSON.stringify([a.paused, a.readyState, a.currentTime, q.paused])")))
        player(act="still"); time.sleep(1.5)
        p = player()
        t.ok(f"{kind}: paused from the player, it stays with play", p["tab"] == u and p["stilled"] and not p["noisy"], p)
        t.ok(f"{kind}: paused from the player, quiet", P("a.paused") is True or not noisy(u))
        time.sleep(4)
        p = player()
        t.ok(f"{kind}: the page quiet a while, still there with play", p["tab"] == u and p["stilled"], p)
        player(act="play")
        t.ok(f"{kind}: played from the player, it plays", until(lambda: noisy(u) and P("!a.paused") is True, within=10))
        p = player()
        t.ok(f"{kind}: playing again, nothing paused", p["tab"] == u and not p["stilled"], p)
        t.ok(f"{kind}: what the page paused itself stays paused", P("q.paused") is True)

        # Paused, then gone to: the pause handed to the page, which plays as
        # it would.
        player(act="still"); time.sleep(1.5)
        player(act="go"); time.sleep(1.5)
        t.ok(f"{kind}: gone to, paused as the page's own pause left it", P("a.paused") is True and not noisy(u))
        P(f"{SAFE}(a), 1")
        t.ok(f"{kind}: gone to, the page's own play plays", until(lambda: noisy(u) and P("!a.paused") is True, within=10))
        select(b)
        t.ok(f"{kind}: left again playing, the player is for it, playing",
             player()["tab"] == u and not player()["stilled"], player())

        # Paused and put away: gone, nothing resumes, the page plays again.
        player(act="still"); time.sleep(1.5); player(act="away"); time.sleep(2)
        t.ok(f"{kind}: put away, no player and quiet", player()["tab"] == "" and not noisy(u) and P("a.paused") is True)
        P(f"{SAFE}(a), 1")
        t.ok(f"{kind}: put away, the page's own play plays", until(lambda: noisy(u), within=10))
        t.ok(f"{kind}: playing again from the page, the player is back", until(lambda: player()["tab"] == u, within=5))

        # Paused, then the page reloads: no row, and the new page plays.
        player(act="still"); time.sleep(1.5)
        sv.cmd({"do": "go", "id": u, "url": f"{sv.BASE}/music2"}); sv.cmd({"do": "wait", "id": u, "seconds": 5}); time.sleep(1)
        t.ok(f"{kind}: the page gone, no player", player()["tab"] == "")
        # A page loaded out of sight loads no media until it is seen, held
        # or not: shown, with nothing paused that select would hand over.
        t.ok(f"{kind}: the page gone, nothing paused", not next(x["stilled"] for x in sv.cmd({"do": "tabs"})["tabs"] if x["id"] == u))
        select(u)
        hush(u); sv.ev(u, f"({MAKE})(document); window.__p = new Audio(window.__silent); 1")
        P(f"{SAFE}(a), 1")
        t.ok(f"{kind}: the next page isn't held: it plays",
             until(lambda: noisy(u) and P("!a.paused") is True, within=10))
        select(b)
        t.ok(f"{kind}: the next page playing, the player is for it", until(lambda: player()["tab"] == u, within=5))

        # Paused, then the tab sleeps: no row.
        player(act="still"); time.sleep(1.5)
        sv.cmd({"do": "sleep", "id": u}); time.sleep(1)
        t.ok(f"{kind}: the tab asleep, no player", player()["tab"] == "")
        sv.sp("close", id=u); time.sleep(1)

finally:
    t.done(); sv.finish()

# The switch off, or the tabs across the top: never a player.
t2 = sv.T()
for prefs, name in (({"sidebar": True, "sidebar.player": False}, "the switch off"),
                    ({"sidebar": False, "sidebar.player": True}, "the tabs across the top")):
    try:
        sv.setup(**prefs)
        sv.launch()
        a = sv.page("a"); sounding(a)
        b = sv.page("b"); select(b)
        t2.ok(f"{name}: no player", player()["tab"] == "")
    finally:
        sv.finish()
t2.done()
sys.exit(1 if t.failed or t2.failed else 0)
