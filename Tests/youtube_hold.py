#!/usr/bin/env python3
"""YouTube's 0:00 hold on return visits (YouTubeAds.swift), measured on
youtube.com itself in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/youtube_hold.py [video…]`.
Needs the network. It runs in a world of its own (bld-ythold-<checkout>)
with split_view.py's harness, started hidden, everything removed
afterwards. Shield is on. Each video is loaded LOADS times in the same tab
and the same world, so from the second load on YouTube knows the visitor
(its cookie is set) and schedules a pre-roll, the case where it used to
hold the video at 0:00 for 5 to 30 seconds once the pre-roll was taken out.

For each load: when the video's own content started, in ms after the
page's navigation began, and whether an ad showed. It fails if an ad
showed, or if a return visit's content started later than LIMIT ms.
The page is hidden, so its player is asked to play as it would on screen
(see STARTED).
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bld-ythold")

VIDEOS = sys.argv[1:] or ["wwYZQjgUljA", "dQw4w9WgXcQ", "9bZkp7q19f0"]
LOADS = 4
LIMIT = 4000
WAIT = 45

# When the video's own content began playing (an ad doesn't count). A
# hidden page doesn't start its video by itself, so it is asked to play the
# way a page on screen would on its own: the player's playVideo, whenever
# the player is there and hasn't started (state -1, or 5 for cued).
STARTED = """(function () {
  var p = document.getElementById('movie_player');
  try { if (p && p.getPlayerState && [-1, 5].indexOf(p.getPlayerState()) >= 0) p.playVideo(); } catch (e) {}
  var v = document.querySelector('#movie_player video');
  var ad = !!document.querySelector('.ad-showing');
  window.__adSeen = window.__adSeen || ad;
  var r = { ad: window.__adSeen };
  if (v && !ad && v.currentTime > 0)
    r.started = Math.round(performance.now() - v.currentTime * 1000 / (v.playbackRate || 1));
  return r;
})()"""


def load(id, url):
    sv.cmd({"do": "go", "id": id, "url": url})
    begun = time.time()
    got = {}
    while time.time() - begun < WAIT:
        time.sleep(0.2)
        try:
            got = sv.ev(id, STARTED) or {}
        except Exception:
            continue
        if got.get("started"):
            break
    return got


t = sv.T()
try:
    sv.setup(shield=True)
    sv.launch()
    id = sv.cmd({"do": "open", "url": "about:blank"})["id"]
    for video in VIDEOS:
        url = f"https://www.youtube.com/watch?v={video}"
        times = []
        for n in range(LOADS):
            sv.cmd({"do": "go", "id": id, "url": "about:blank"}); time.sleep(1)
            got = load(id, url)
            times.append(got.get("started"))
            print(f"  {video} load {n + 1}: content at {got.get('started')} ms, ad seen: {bool(got.get('ad'))}")
            t.ok(f"{video} load {n + 1}: no ad", not got.get("ad"), got)
        later = times[1:]
        t.ok(f"{video}: return visits start within {LIMIT} ms",
             all(x is not None and x < LIMIT for x in later), times)
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
