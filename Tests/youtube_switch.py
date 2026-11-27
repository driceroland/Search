#!/usr/bin/env python3
"""Leaving a YouTube tab and coming back: what the page goes through (youtube-switch).

Build first (`./build.sh`), then `python3 Tests/youtube_switch.py [VIDEO] [--rounds R] [--nofloat] [--out FILE]`.
YT_APP=/path/to/Search.app measures another build.
Needs the network. A hidden probe in a world of its own (split_view.py's
harness, SEARCH_MEASURE=1 so hidden pages are slowed the way WebKit slows
them), three tabs from the session: YouTube's watch page, and two local
ones. No sound, ever: the tab is muted at WebKit's page level (Bench
`mute`) before anything plays, the player is muted and its volume set to 0,
and nothing is played until the page says it is muted.

Per round:
- away and back at once (the tab is awake the whole time): was the page
  reloaded (its performance.timeOrigin), was the player's video element
  the same one, did the video's clock go on, how long the pick held the
  main thread (perfselect), and how many events the page got
  (visibilitychange, pause, play, emptied, waiting, stalled) in the
  meantime;
- the same with the video paused first;
- away long enough for the tab to sleep (`sleep.after` is 8 s here) and
  back: the time until the page's player has a video that plays again,
  next to the time the first load took. Waking is a load of the page,
  which is all a sleeping tab can do, and the answer says so.

The window is never shown: what a person sees on screen as the tab
changes (the floating video, the picture over a waking tab) can't be
proven here and isn't tried. A muted video isn't heard, so the floating
window never opens (Browser.lift); this probe never makes one.
"""
import json
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import perf_tools  # noqa: E402
import split_view as sv  # noqa: E402

sv.use("youtube-switch")
import os as _os
if _os.environ.get("YT_APP"):
    sv.APP = _os.environ["YT_APP"]
VIDEO = next((a for a in sys.argv[1:] if not a.startswith("--") and len(a) == 11), "jNQXAC9IVRw")
SECOND_SPACE = None

# The player muted, in every way the page allows, and checked.
MUTE = """(function () {
  var p = document.getElementById('movie_player');
  try { if (p && p.mute) { p.mute(); p.setVolume(0); } } catch (e) {}
  var v = document.querySelector('#movie_player video, video');
  if (v) { v.muted = true; v.volume = 0; }
  return !!(v && v.muted && v.volume === 0);
})()"""

PLAY = """(function () {
  var p = document.getElementById('movie_player');
  var v = document.querySelector('#movie_player video, video');
  if (!v || !v.muted) return 'not muted';
  try { if (p && p.playVideo) p.playVideo(); else v.play(); } catch (e) {}
  return 'asked';
})()"""

PAUSE = """(function () {
  var p = document.getElementById('movie_player');
  try { if (p && p.pauseVideo) p.pauseVideo(); else document.querySelector('video').pause(); } catch (e) {}
  return 1;
})()"""

WATCH = """(function () {
  if (window.__yt) return 'on';
  var log = window.__yt = { events: {}, vid: null, origin: performance.timeOrigin };
  var v = document.querySelector('#movie_player video, video');
  log.vid = v;
  ['pause', 'play', 'playing', 'emptied', 'waiting', 'stalled', 'seeking', 'loadstart'].forEach(function (n) {
    document.addEventListener(n, function (e) { if (e.target instanceof HTMLVideoElement) log.events[n] = (log.events[n] || 0) + 1; }, true);
  });
  document.addEventListener('visibilitychange', function () { log.events.visibility = (log.events.visibility || 0) + 1; });
  return 'set';
})()"""

STATE = """(function () {
  var v = document.querySelector('#movie_player video, video');
  var log = window.__yt || {};
  return JSON.stringify({ origin: performance.timeOrigin, same: !!(log.vid && v === log.vid), reloaded: !log.vid,
    t: v ? v.currentTime : null, paused: v ? v.paused : null, ready: v ? v.readyState : null,
    muted: v ? v.muted : null, events: log.events || {}, hidden: document.visibilityState });
})()"""


class Watch(threading.Thread):
    """Every quarter second: the probe hidden again, and counted if a window of it was ever on a screen."""
    def __init__(self, pid):
        super().__init__(daemon=True)
        self.pid, self.stop, self.onscreen, self.exe = pid, False, 0, perf_tools.hide()

    def run(self):
        while not self.stop:
            if "onscreen" in subprocess.run([self.exe, str(self.pid)], capture_output=True, text=True).stdout:
                self.onscreen += 1
            time.sleep(0.25)


def state(id):
    try:
        return json.loads(sv.ev(id, STATE))
    except Exception as e:
        return {"error": str(e)}


def wait_playing(id, within=40):
    """Seconds until the video has played past 0.5 s, the page muted."""
    t0 = time.time()
    while time.time() - t0 < within:
        s = state(id)
        if s.get("t") and s["t"] > 0.5 and s.get("ready", 0) >= 3 and not s.get("paused"):
            return round(time.time() - t0, 2)
        try:
            sv.ev(id, PLAY)
        except Exception:
            pass
        time.sleep(0.5)
    return None


def tabs():
    return sv.cmd({"do": "tabs"})["tabs"]


def main():
    a = sys.argv[1:]
    rounds = int(a[a.index("--rounds") + 1]) if "--rounds" in a else 2
    outfile = a[a.index("--out") + 1] if "--out" in a else None
    sv.setup()
    subprocess.run(["defaults", "write", sv.SUITE, "sleep.after", "-float", "8"])
    # --nofloat: Settings › Video › Float the video on its own, Never. A page
    # in a probe is always hidden, so a video paused by hand there floats all
    # the same (WebKit's own pause of a hidden page is told by that), and a
    # video in the little window keeps its tab awake: asleep only without it.
    if "--nofloat" in a:
        subprocess.run(["defaults", "write", sv.SUITE, "float.leave", "-bool", "false"])
    import os
    os.makedirs(sv.SUPPORT, exist_ok=True)
    json.dump({"tabs": [{"url": f"https://www.youtube.com/watch?v={VIDEO}", "title": "YouTube"},
                        {"url": f"{sv.BASE}/other-one", "title": "One"},
                        {"url": f"{sv.BASE}/other-two", "title": "Two"}], "active": 0},
              open(f"{sv.SUPPORT}/session.json", "w"))
    results = []
    try:
        # Not pmt's launch: the probe is slowed as shipped, hidden.
        if os.path.exists(sv.SOCK):
            os.remove(sv.SOCK)
        before = sv.running()
        subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_MEASURE=1", sv.APP])
        for _ in range(300):
            if os.path.exists(sv.SOCK):
                break
            time.sleep(0.1)
        time.sleep(2)
        sv.started.update((sv.running() - before) & sv.holding())
        watch = Watch(int(sv.pids()[0]))
        watch.start()
        row = tabs()
        yt, one, two = row[0]["id"], row[1]["id"], row[2]["id"]
        t0 = time.time()
        sv.cmd({"do": "wait", "id": yt, "seconds": 30})
        first_load = round(time.time() - t0, 2)
        # Mute at the source before anything plays.
        sv.cmd({"do": "mute", "id": yt})
        tab = next(t for t in tabs() if t["id"] == yt)
        if not tab.get("muted"):
            sys.exit("the tab didn't report muted: not playing anything")
        for _ in range(40):
            if sv.ev(yt, MUTE) is True:
                break
            time.sleep(0.5)
        else:
            sys.exit("the player never reported muted: not playing anything")
        sv.ev(yt, WATCH)
        started = wait_playing(yt)
        print(json.dumps({"first_load_s": first_load, "playing_after_s": started, "state": state(yt)}), flush=True)
        for rnd in range(rounds):
            for label, pause_first in (("playing", False), ("paused", True)):
                if pause_first:
                    sv.ev(yt, PAUSE)
                    time.sleep(1)
                before_state = state(yt)
                sv.cmd({"do": "select", "id": one})
                time.sleep(2)
                away = state(yt)
                index = next(i for i, t in enumerate(tabs()) if t["id"] == yt)
                back = sv.cmd({"do": "perfselect", "index": index, "seconds": 1.5})
                time.sleep(1.5)
                after = state(yt)
                res = {"round": rnd, "case": label, "reloaded": after.get("origin") != before_state.get("origin"),
                       "sameVideoElement": after.get("same"), "clockBefore": before_state.get("t"),
                       "clockAway": away.get("t"), "clockAfter": after.get("t"), "pausedAfter": after.get("paused"),
                       "events": after.get("events"), "pickMs": back.get("callMs"), "longestMs": back.get("longestMs"),
                       "busyMs": back.get("busyMs")}
                print(json.dumps(res), flush=True)
                results.append(res)
            # Long enough away to sleep: paused first (a video in the little
            # window keeps its tab awake, as it should).
            sv.ev(yt, PAUSE)
            time.sleep(1)
            sv.cmd({"do": "select", "id": two})
            for _ in range(40):
                time.sleep(2)
                if next(t for t in tabs() if t["id"] == yt).get("asleep"):
                    break
            asleep = next(t for t in tabs() if t["id"] == yt).get("asleep")
            index = next(i for i, t in enumerate(tabs()) if t["id"] == yt)
            woke = time.time()
            back = sv.cmd({"do": "perfselect", "index": index, "seconds": 1.5})
            sv.cmd({"do": "wait", "id": yt, "seconds": 30})
            loaded = round(time.time() - woke, 2)
            for _ in range(40):
                if sv.ev(yt, MUTE) is True:
                    break
                time.sleep(0.5)
            else:
                sys.exit("the woken player never reported muted")
            sv.ev(yt, WATCH)
            playing = wait_playing(yt)
            res = {"round": rnd, "case": "slept", "float": "--nofloat" not in a, "wasAsleep": asleep, "pickMs": back.get("callMs"),
                   "longestMs": back.get("longestMs"), "loadedAfterS": loaded, "playsAfterS": playing,
                   "firstLoadS": first_load, "firstPlayS": started}
            print(json.dumps(res), flush=True)
            results.append(res)
        watch.stop = True
        print(json.dumps({"windowOnScreenSamples": watch.onscreen}), flush=True)
    finally:
        sv.finish()
    if outfile:
        Path(outfile).write_text("\n".join(json.dumps(r) for r in results))


if __name__ == "__main__":
    main()
