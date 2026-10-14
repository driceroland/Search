#!/usr/bin/env python3
"""A paused tab hands the media keys back (#512), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/media_keys.py`. It uses the
split suite's harness: started hidden, no window made or shown, everything
removed afterwards. Whether Search is the Mac's Now Playing app, the one the
play/pause keys and AirPods taps go to, is read from WebKit (`nowplaying`).
The sound is a quiet tone the page makes itself.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# Its own world, apart from the split suite's in this checkout (see use()).
sv.use("media-keys")

# How long a paused tab keeps the keys (MediaKeys.swift), and a margin.
KEEP = 10
# A 440 Hz tone, half a minute of it, as a page's <audio>, plus a count of
# the volumechange events the page itself hears.
TONE = """(function () {
  var r = 8000, n = r * 30, b = new ArrayBuffer(44 + n * 2), d = new DataView(b);
  function s(o, t) { for (var i = 0; i < t.length; i++) d.setUint8(o + i, t.charCodeAt(i)) }
  s(0, 'RIFF'); d.setUint32(4, 36 + n * 2, true); s(8, 'WAVEfmt '); d.setUint32(16, 16, true);
  d.setUint16(20, 1, true); d.setUint16(22, 1, true); d.setUint32(24, r, true); d.setUint32(28, r * 2, true);
  d.setUint16(32, 2, true); d.setUint16(34, 16, true); s(36, 'data'); d.setUint32(40, n * 2, true);
  for (var i = 0; i < n; i++) d.setInt16(44 + i * 2, Math.sin(i / r * 2 * Math.PI * 440) * 800, true);
  var a = document.createElement('audio'); a.id = 't';
  a.src = URL.createObjectURL(new Blob([b], { type: 'audio/wav' }));
  window.__heard = 0; a.addEventListener('volumechange', function () { window.__heard++ });
  document.body.appendChild(a); return 1;
})()"""

t = sv.T()
def ev(js): return sv.cmd({"do": "eval", "id": tab, "js": js}).get("value")
def keys(): return sv.cmd({"do": "nowplaying", "id": tab})["registered"]
def audio(js): return ev(f"(function (a) {{ return {js} }})(document.getElementById('t'))")
try:
    sv.setup(); sv.launch()
    tab = sv.page("a"); sv.cmd({"do": "select", "id": tab}); sv.cmd({"do": "wait", "id": tab, "seconds": 5})
    ev(TONE)

    audio("a.play(), 1"); time.sleep(1.5)
    t.ok("playing: Search has the keys", keys())

    # Paused, then played again with the key a moment later: still Search's.
    audio("a.pause(), 1"); time.sleep(2)
    t.ok("paused a moment: Search keeps the keys", keys())
    audio("a.play(), 1"); time.sleep(1.5)
    t.ok("played again: still Search's", keys() and audio("!a.paused"))

    # Paused for longer: the keys go back, and the page can't tell.
    audio("a.pause(), 1"); time.sleep(KEEP + 2)
    t.ok("paused a while: the keys go back", not keys())
    t.ok("paused a while: the page still reads it unmuted", audio("a.muted") is False)
    t.ok("paused a while: the page heard no volume change", ev("window.__heard") == 0, ev("window.__heard"))

    # Played again: with its sound, and the keys are Search's again.
    audio("a.play(), 1"); time.sleep(1.5)
    t.ok("played after a while: Search has the keys again", keys())
    t.ok("played after a while: with its sound", audio("!a.paused && !a.muted") is True)
    t.ok("played after a while: still no volume change heard", ev("window.__heard") == 0, ev("window.__heard"))

    # The page's own mute is the page's: kept through a pause and a play.
    audio("a.muted = true, 1"); time.sleep(0.5)
    heard = ev("window.__heard")
    t.ok("the page's own mute: the page hears it", heard == 1, heard)
    audio("a.pause(), 1"); time.sleep(KEEP + 2)
    audio("a.play(), 1"); time.sleep(1.5)
    t.ok("the page's own mute: still muted after a pause and a play", audio("a.muted") is True)
    audio("a.muted = false, 1"); time.sleep(1.5)
    t.ok("the page unmutes: Search has the keys", keys() and audio("!a.muted") is True)

    # Unmuted by the page while the keys are given back: it reads what it set,
    # and plays with sound.
    audio("a.muted = true, a.pause(), 1"); time.sleep(0.5)
    audio("a.muted = false, 1"); time.sleep(KEEP + 2)
    t.ok("unmuted by the page while paused: it reads unmuted", audio("a.muted") is False)
    t.ok("unmuted by the page while paused: the keys go back", not keys())
    audio("a.play(), 1"); time.sleep(1.5)
    t.ok("unmuted by the page while paused: plays with its sound", keys() and audio("!a.muted") is True)

    # Every volume change of its own is still heard: none of ours is left
    # waiting to take the place of one of the page's.
    before = ev("window.__heard"); audio("a.volume = 0.5, 1"); time.sleep(0.5)
    t.ok("after all that: the page hears its own volume change", ev("window.__heard") == before + 1, (before, ev("window.__heard")))

    # Given back, the page setting what it already reads hears nothing, as
    # with WebKit; a page that sets it again from its own listener doesn't
    # go round for ever.
    audio("a.pause(), 1"); time.sleep(KEEP + 2)
    before = ev("window.__heard")
    audio("a.addEventListener('volumechange', function () { a.muted = a.muted }), a.muted = false, 1"); time.sleep(0.5)
    t.ok("given back, set to what it reads: nothing heard", ev("window.__heard") == before, (before, ev("window.__heard")))
    audio("a.muted = true, 1"); time.sleep(0.5)
    t.ok("given back, set to something else: heard once, a moment later", ev("window.__heard") == before + 1, (before, ev("window.__heard")))
    audio("a.muted = false, a.play(), 1"); time.sleep(1.5)

    # Unmuted by the video's own controls while given back (they read the
    # real value, from another world): that wins, and nothing is left owed.
    audio("a.pause(), 1"); time.sleep(KEEP + 2)
    t.ok("given back again", not keys())
    sv.cmd({"do": "eval", "id": tab, "world": "search", "js": "document.getElementById('t').muted = false; 1"}); time.sleep(0.5)
    audio("a.play(), 1"); time.sleep(1.5)
    t.ok("unmuted by its controls: plays with its sound", keys() and audio("!a.muted") is True)
    before = ev("window.__heard"); audio("a.volume = 0.4, 1"); time.sleep(0.5)
    t.ok("unmuted by its controls: the page's next change is heard", ev("window.__heard") == before + 1, (before, ev("window.__heard")))

    # Taken out of the page while paused: given back all the same, and put
    # back and played, with its sound and nothing owed.
    audio("window.__a = a, a.pause(), a.remove(), 1"); time.sleep(KEEP + 2)
    t.ok("taken out of the page while paused: the keys go back", not keys())
    ev("document.body.appendChild(window.__a).play(), 1"); time.sleep(1.5)
    t.ok("put back and played: with its sound", keys() and audio("!a.muted") is True)
    before = ev("window.__heard"); audio("a.volume = 0.3, 1"); time.sleep(0.5)
    t.ok("put back and played: the page's next change is heard", ev("window.__heard") == before + 1, (before, ev("window.__heard")))

    # One never put in the page, as new Audio() makes: the same.
    audio("a.pause(), 1")
    ev("window.__loose = new Audio(document.getElementById('t').src); window.__loose.play(); 1"); time.sleep(1.5)
    t.ok("new Audio(), playing: Search has the keys", keys())
    ev("window.__loose.pause(); 1"); time.sleep(KEEP + 2)
    t.ok("new Audio(), paused a while: the keys go back", not keys())
    t.ok("new Audio(), paused a while: it reads unmuted", ev("window.__loose.muted") is False)
    ev("window.__loose.play(); 1"); time.sleep(1.5)
    t.ok("new Audio(), played again: with its sound, and the keys", keys() and ev("!window.__loose.muted") is True)
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
