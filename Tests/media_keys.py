#!/usr/bin/env python3
"""A paused tab hands the media keys back (#512), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/media_keys.py`. It uses the
split suite's harness: started hidden, no window made or shown, everything
removed afterwards. Whether Search is the Mac's Now Playing app, the one the
play/pause keys and AirPods taps go to, is read from WebKit (`nowplaying`).
The sound is a quiet tone the page makes itself. The last part plays a
YouTube video, and is skipped when YouTube doesn't load.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# Its own world, apart from the split suite's in this checkout (see use()).
sv.use("media-keys")

# How long a quiet tab keeps the keys (MediaKeys.swift), and a margin.
KEEP = 10
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

t = sv.T()
def ev(js): return sv.cmd({"do": "eval", "id": tab, "js": js}).get("value")
def np(): return sv.cmd({"do": "nowplaying", "id": tab})
def keys(): return np()["registered"]
def audio(js, inner=False):
    doc = "document.querySelector('iframe').contentDocument" if inner else "document"
    return ev(f"(function (a) {{ return {js} }})({doc}.getElementById('t'))")
try:
    sv.setup(); sv.launch()
    tab = sv.page("a"); sv.cmd({"do": "select", "id": tab}); sv.cmd({"do": "wait", "id": tab, "seconds": 5})
    ev(f"({MAKE})(document)")
    # A second player that never plays.
    ev("var u = document.createElement('audio'); u.id = 'u'; u.src = document.getElementById('t').src; document.body.appendChild(u); 1")

    audio("a.play(), 1"); time.sleep(1.5)
    t.ok("playing: Search has the keys", keys())
    t.ok("playing: no timer", np()["hushing"] is False)

    # Paused, then played again with the key a moment later: still Search's.
    audio("a.pause(), 1"); time.sleep(2)
    t.ok("paused a moment: Search keeps the keys", keys())
    t.ok("paused a moment: one timer counting", np()["hushing"] is True)
    audio("a.play(), 1"); time.sleep(1.5)
    t.ok("played again: still Search's, and the timer gone", keys() and np()["hushing"] is False)

    # Paused for longer: the keys go back, and the page reads what's so.
    audio("a.pause(), 1"); time.sleep(KEEP + 2)
    t.ok("paused a while: the keys go back", not keys())
    t.ok("paused a while: the page reads it muted, as it is", audio("a.muted") is True)
    t.ok("paused a while: the timer gone once it has run", np()["hushing"] is False)
    t.ok("paused a while: a player that never played is left alone", ev("document.getElementById('u').muted") is False)

    # Played again: with its sound, and the keys are Search's again.
    audio("a.play(), 1"); time.sleep(1.5)
    t.ok("played after a while: with its sound", audio("!a.paused && !a.muted") is True)
    t.ok("played after a while: Search has the keys again", keys())

    # Held, then taken out of the page and played there: its sound back.
    audio("a.pause(), 1"); time.sleep(KEEP + 2)
    audio("window.__a = a, a.remove(), 1"); time.sleep(0.5)
    ev("window.__a.play(), 1"); time.sleep(1.5)
    t.ok("held, taken out of the page and played: with its sound", ev("!window.__a.paused && !window.__a.muted") is True)
    ev("document.body.appendChild(window.__a), 1"); time.sleep(0.5)

    # A page that mutes itself keeps it: never touched, never unmuted.
    audio("a.muted = true, 1"); time.sleep(1); audio("a.pause(), 1"); time.sleep(KEEP + 2)
    audio("a.play(), 1"); time.sleep(1.5)
    t.ok("muted by the page: still muted after a pause and a play", audio("a.muted") is True)

    # Unmuted by the page while Search holds it: the page's answer wins, and
    # Search forgets it, so a mute of the page's own afterwards stays.
    audio("a.muted = false, 1"); time.sleep(1.5); audio("a.pause(), 1"); time.sleep(KEEP + 2)
    t.ok("held: the keys go back", not keys())
    audio("a.muted = false, 1"); time.sleep(1)
    t.ok("unmuted by the page while held: it reads what it set", audio("a.muted") is False)
    audio("a.muted = true, a.play(), 1"); time.sleep(1.5)
    t.ok("unmuted by the page while held: forgotten, so its own mute stays", audio("a.muted") is True)
    audio("a.pause(), a.muted = false, 1")

    # In a frame of its own: looked in too.
    ev(f"var f = document.createElement('iframe'); f.src = '{sv.BASE}/inner'; document.body.appendChild(f); 1"); time.sleep(2.5)
    ev(f"({MAKE})(document.querySelector('iframe').contentDocument)")
    audio("a.play(), 1", inner=True); time.sleep(1.5)
    t.ok("in a frame, playing: Search has the keys", keys())
    audio("a.pause(), 1", inner=True); time.sleep(KEEP + 2)
    t.ok("in a frame, paused a while: the keys go back", not keys())
    audio("a.play(), 1", inner=True); time.sleep(1.5)
    t.ok("in a frame, played again: with its sound, and the keys", keys() and audio("!a.muted", inner=True) is True)
    audio("a.pause(), 1", inner=True)

    # YouTube, as people play it.
    sv.cmd({"do": "go", "id": tab, "url": "https://www.youtube.com/watch?v=aqz-KE-bpKQ"})
    sv.cmd({"do": "wait", "id": tab, "seconds": 25}); time.sleep(6)
    V = "document.querySelector('video')"
    if ev(f"!!{V}"):
        ev(f"{V}.play(), 1"); time.sleep(4)
        playing = keys()
        ev(f"{V}.pause(), 1"); time.sleep(KEEP + 3)
        t.ok("YouTube: playing, Search has the keys; paused a while, they go back", playing and not keys())
        ev(f"{V}.play(), 1"); time.sleep(3)
        t.ok("YouTube: played again, with its sound and the keys", ev(f"!{V}.paused && !{V}.muted") is True and keys())
    else:
        print("  skip  YouTube didn't load")
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
