#!/usr/bin/env python3
"""What plays in another tab, at the foot of the sidebar, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/media_player.py`. It uses the
split suite's harness: started hidden, no window made or shown, everything
removed afterwards. The player is read and pressed through the bench's
`player`, as its buttons would.

First on a quiet tone the page makes itself, in the page and in a frame of
its own; then on sites as people play them — a radio's live stream opened
as a page, a YouTube video, a live channel on Twitch — each skipped when the
site doesn't load or doesn't play. The video sites' videos float out when
you go to another tab (Settings › Videos), which would open the floating
window: that is turned off here, and how the row stays out of the way of a
floating video is checked by hand. So is how the row looks, or with the
bench's `column` picture.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# Its own world, apart from the split suite's in this checkout (see use()).
sv.use("media-player")

# A 440 Hz tone, half a minute of it, as an <audio id=t> in the given document.
MAKE = """function (doc) {
  var r = 8000, n = r * 30, b = new ArrayBuffer(44 + n * 2), d = new DataView(b);
  function s(o, t) { for (var i = 0; i < t.length; i++) d.setUint8(o + i, t.charCodeAt(i)) }
  s(0, 'RIFF'); d.setUint32(4, 36 + n * 2, true); s(8, 'WAVEfmt '); d.setUint32(16, 16, true);
  d.setUint16(20, 1, true); d.setUint16(22, 1, true); d.setUint32(24, r, true); d.setUint32(28, r * 2, true);
  d.setUint16(32, 2, true); d.setUint16(34, 16, true); s(36, 'data'); d.setUint32(40, n * 2, true);
  for (var i = 0; i < n; i++) d.setInt16(44 + i * 2, Math.sin(i / r * 2 * Math.PI * 440) * 800, true);
  var a = doc.createElement('audio'); a.id = 't';
  a.src = URL.createObjectURL(new Blob([b], { type: 'audio/wav' }));
  doc.body.appendChild(a); return 1;
}"""
INNER = "document.querySelector('iframe').contentDocument"

t = sv.T()
def player(**f): return sv.cmd({"do": "player", **f})
def select(id): sv.cmd({"do": "select", "id": id}); time.sleep(1)
def tone(id, js, inner=False):
    doc = INNER if inner else "document"
    return sv.ev(id, f"(function (a) {{ return {js} }})({doc}.getElementById('t'))")
def noisy(id): return next((x["noisy"] for x in sv.cmd({"do": "tabs"})["tabs"] if x["id"] == id), False)
def sounding(id):
    """A page that plays its tone, picked so that it starts on screen."""
    select(id); sv.cmd({"do": "wait", "id": id, "seconds": 5})
    sv.ev(id, f"({MAKE})(document)"); tone(id, "a.play(), 1"); time.sleep(1.5)
def until(check, within=20, every=0.5):
    end = time.time() + within
    while time.time() < end:
        if check(): return True
        time.sleep(every)
    return False

# A site's own player, as people play it: loaded on screen, started with its
# sound, then left for another tab, paused and played again from the player.
MEDIA = "document.querySelector('video, audio')"
def site(name, url, away, start=f"(function () {{ var v = {MEDIA}; v.muted = false; v.play(); return 1 }})()",
         ready=None, settle=6):
    tab = sv.sp("open", url=url)["resultID"]
    try:
        select(tab); sv.cmd({"do": "wait", "id": tab, "seconds": 25}); time.sleep(settle)
        if ready: sv.ev(tab, ready); time.sleep(settle)
        if not sv.ev(tab, f"!!{MEDIA}"):
            print(f"  skip  {name}: nothing to play (didn't load?)"); return
        sv.ev(tab, start)
        if not until(lambda: noisy(tab), within=15):
            print(f"  skip  {name}: never made a sound"); return
        select(away)
        p = player()
        t.ok(f"{name}: out of sight, the player is for it", p["tab"] == tab and p["noisy"], p)
        player(act="still")
        paused = until(lambda: sv.ev(tab, f"{MEDIA}.paused") is True and not noisy(tab), within=5)
        t.ok(f"{name}: paused from the player, the page's player is paused", paused)
        p = player()
        if p["stilled"]:
            t.ok(f"{name}: paused from the player, the row stays", p["tab"] == tab, p)
            player(act="play")
            t.ok(f"{name}: played again from the player, with its sound",
                 until(lambda: sv.ev(tab, f"!{MEDIA}.paused && !{MEDIA}.muted") is True and noisy(tab), within=15))
            t.ok(f"{name}: playing again, nothing paused", player()["stilled"] is False)
        else:
            # Paused by WebKit only, out of a script's reach: nothing to play
            # again, and no row offering to.
            t.ok(f"{name}: nothing it could play again, so no row", p["tab"] != tab, p)
    finally:
        try: sv.sp("close", id=tab)
        except Exception: pass
        time.sleep(1)

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
    player(act="play"); time.sleep(1.5)
    p = player()
    t.ok("played from the player: playing, nothing paused", p["tab"] == a and p["noisy"] and not p["stilled"], p)
    t.ok("played from the player: the page's tone plays", tone(a, "!a.paused && !a.muted") is True)

    # Paused and put away: gone until it plays again.
    player(act="still"); time.sleep(1.5); player(act="away"); time.sleep(0.5)
    t.ok("put away: no player", player()["tab"] == "")
    tone(a, "a.play(), 1"); time.sleep(1.5)
    t.ok("played again by the page: the player is back", player()["tab"] == a)

    # Quiet for longer than the media keys wait (MediaKeys.swift): the tone
    # is muted to give the keys back, and played from the player it is
    # heard again.
    player(act="still"); time.sleep(12)
    t.ok("paused a while: still in the row", player()["stilled"] is True)
    player(act="play"); time.sleep(1.5)
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
    f = sv.page("framed"); select(f)
    sv.ev(f, f"var e = document.createElement('iframe'); e.src = '{sv.BASE}/inner'; document.body.appendChild(e); 1"); time.sleep(2.5)
    sv.ev(f, f"({MAKE})({INNER})"); tone(f, "a.play(), 1", inner=True); time.sleep(1.5)
    select(b)
    t.ok("in a frame: the player is for its page", player()["tab"] == f)
    player(act="still"); time.sleep(1.5)
    t.ok("in a frame: paused there, and the row stays",
         tone(f, "a.paused", inner=True) is True and player()["stilled"] is True)
    player(act="play"); time.sleep(1.5)
    t.ok("in a frame: played again there", tone(f, "!a.paused && !a.muted", inner=True) is True)
    tone(f, "a.pause(), 1", inner=True); time.sleep(1)

    # Sites, as people play them.
    site("France Inter's live stream", "https://icecast.radiofrance.fr/franceinter-midfi.mp3", b)
    # YouTube's consent page, where there is one, refused first.
    site("YouTube", "https://www.youtube.com/watch?v=aqz-KE-bpKQ", b, ready="""(function () {
      var no = Array.from(document.querySelectorAll('button')).find(function (x) {
        return /^(reject all|tout refuser|alle ablehnen)$/i.test((x.innerText || '').trim()); });
      if (no) no.click(); return 1 })()""")
    # Twitch: a channel live now, from the directory; past the mature-content
    # gate if it has one, and unmuted the way its player keeps it.
    d = sv.sp("open", url="https://www.twitch.tv/directory/all")["resultID"]
    select(d); sv.cmd({"do": "wait", "id": d, "seconds": 25})
    live = ""
    until(lambda: bool(sv.ev(d, "!!document.querySelector('a[data-a-target=\"preview-card-image-link\"]')")), within=20)
    live = sv.ev(d, "(function () { var a = document.querySelector('a[data-a-target=\"preview-card-image-link\"]'); return a ? a.href : '' })()") or ""
    sv.sp("close", id=d); time.sleep(1)
    if live:
        site(f"Twitch ({live.rstrip('/').split('/')[-1]}, live)", live, b, settle=8,
             ready="""(function () {
               try { localStorage.setItem('video-muted', '{"default":false}'); localStorage.setItem('volume', '0.3'); } catch (e) {}
               var gate = document.querySelector('[data-a-target="content-classification-gate-overlay-start-watching-button"], [data-a-target="player-overlay-mature-accept"]');
               if (gate) gate.click(); return 1 })()""",
             start=f"(function () {{ var v = {MEDIA}; v.muted = false; v.volume = 0.3; v.play(); return 1 }})()")
    else:
        print("  skip  Twitch: no live channel found (didn't load?)")
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
