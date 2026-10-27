#!/usr/bin/env python3
"""What plays in another tab, at the foot of the sidebar, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/media_player.py`. It uses the
split suite's harness: started hidden, no window made or shown, everything
removed afterwards. The player is read and pressed through the bench's
`player`, as its buttons would; the sound is a quiet tone the page makes
itself. How the row looks is checked by hand on a release candidate, or
with the bench's `column` picture.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# Its own world, apart from the split suite's in this checkout (see use()).
sv.use("media-player")

# A 440 Hz tone, half a minute of it, as an <audio id=t> in the page.
MAKE = """(function () {
  var r = 8000, n = r * 30, b = new ArrayBuffer(44 + n * 2), d = new DataView(b);
  function s(o, t) { for (var i = 0; i < t.length; i++) d.setUint8(o + i, t.charCodeAt(i)) }
  s(0, 'RIFF'); d.setUint32(4, 36 + n * 2, true); s(8, 'WAVEfmt '); d.setUint32(16, 16, true);
  d.setUint16(20, 1, true); d.setUint16(22, 1, true); d.setUint32(24, r, true); d.setUint32(28, r * 2, true);
  d.setUint16(32, 2, true); d.setUint16(34, 16, true); s(36, 'data'); d.setUint32(40, n * 2, true);
  for (var i = 0; i < n; i++) d.setInt16(44 + i * 2, Math.sin(i / r * 2 * Math.PI * 440) * 800, true);
  var a = document.createElement('audio'); a.id = 't';
  a.src = URL.createObjectURL(new Blob([b], { type: 'audio/wav' }));
  document.body.appendChild(a); return 1;
})()"""

t = sv.T()
def player(**f): return sv.cmd({"do": "player", **f})
def select(id): sv.cmd({"do": "select", "id": id}); time.sleep(1)
def tone(id, js): return sv.ev(id, f"(function (a) {{ return {js} }})(document.getElementById('t'))")
def sounding(id):
    """A page that plays its tone, picked so that it starts on screen."""
    select(id); sv.cmd({"do": "wait", "id": id, "seconds": 5})
    sv.ev(id, MAKE); tone(id, "a.play(), 1"); time.sleep(1.5)
try:
    sv.setup(**{"sidebar": True, "sidebar.player": True})
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
    player(act="play"); time.sleep(1.5)
    p = player()
    t.ok("played from the player: playing, nothing paused", p["tab"] == a and p["noisy"] and not p["stilled"], p)
    t.ok("played from the player: the page's tone plays", tone(a, "!a.paused && !a.muted") is True)

    # Paused and put away: gone until it plays again.
    player(act="still"); time.sleep(1.5); player(act="away"); time.sleep(0.5)
    t.ok("put away: no player", player()["tab"] == "")
    tone(a, "a.play(), 1"); time.sleep(1.5)
    t.ok("played again by the page: the player is back", player()["tab"] == a)

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
