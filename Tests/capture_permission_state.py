#!/usr/bin/env python3
"""What navigator.permissions.query says of the camera and microphone
(Browser's queryPermission), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/capture_permission_state.py`.
Google Meet, told it is Chrome by the Meet mini window's shim, reads its
camera and microphone state from navigator.permissions, not from
getUserMedia: WebKit said "prompt" for a site Search lets straight in, so
Meet showed both buttons waiting for permission and flashed "Click Allow".
Now the answer is what Search would do, and a choice made in Search's
question reaches the page as a 'change' event. WebKit's pretend camera and
microphone only; nothing shown, no sound.
"""
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("capture-state")
t = sv.T()
OTHER = sv.BASE.replace("127.0.0.1", "localhost")


def until(cond, within=6):
    end = time.time() + within
    while time.time() < end:
        try:
            if cond(): return True
        except Exception:
            pass
        time.sleep(0.2)
    return cond()


QUERY = ("window.Q = {}; window.changes = [];"
         "['camera','microphone'].forEach(function (n) { navigator.permissions.query({name: n}).then(function (s) {"
         " Q[n] = s.state; s.onchange = function () { changes.push(n + ' ' + s.state); Q[n] = s.state; }; }); }); 1")


def states(id):
    sv.ev(id, QUERY)
    until(lambda: json.loads(sv.ev(id, "JSON.stringify(Q)")).keys() >= {"camera", "microphone"}, 4)
    return json.loads(sv.ev(id, "JSON.stringify(Q)"))


try:
    sv.setup(splitView=False)
    # 127.0.0.1: camera always allowed, microphone refused; localhost: nothing.
    subprocess.run(["defaults", "write", sv.SUITE, f"capture.{sv.BASE}|0", "-bool", "true"])
    subprocess.run(["defaults", "write", sv.SUITE, f"capture.{sv.BASE}|1", "-bool", "false"])
    sv.launch()

    known = sv.page("known")
    q = states(known)
    t.ok("a site always let in to the camera hears 'granted'", q.get("camera") == "granted", q)
    t.ok("a refused microphone is not told 'denied' before it asks (WebKit keeps that back)", q.get("microphone") == "prompt", q)

    fresh = sv.sp("open", url=f"{OTHER}/fresh")["resultID"]; time.sleep(0.7)
    q = states(fresh)
    t.ok("a site never answered hears 'prompt' for both", q == {"camera": "prompt", "microphone": "prompt"}, q)

    # It asks; Search asks you; "always allow": the page hears it changed.
    sv.ev(fresh, "navigator.mediaDevices.getUserMedia({video: true}).then(function (s) { window.got = s.getVideoTracks()[0].label; s.getTracks().forEach(function (x) { x.stop(); }); }, function (e) { window.got = 'error ' + e.name; }); 1")
    asking = lambda: sv.cmd({"do": "notifications"}).get("asking", "")
    t.ok("Search asks about the camera", until(lambda: "camera" in asking(), 10), asking())
    time.sleep(0.7)
    sv.cmd({"do": "answer", "with": "always"})
    t.ok("allowed: the page gets WebKit's pretend camera", until(lambda: "Mock" in (sv.ev(fresh, "window.got") or ""), 10), sv.ev(fresh, "window.got"))
    t.ok("and its permission status changes to 'granted' by itself ('change' event)",
         until(lambda: "camera granted" in json.loads(sv.ev(fresh, "JSON.stringify(changes)")), 5), sv.ev(fresh, "JSON.stringify(changes)"))
    q = states(fresh)
    t.ok("asked again: camera 'granted', microphone still 'prompt'", q == {"camera": "granted", "microphone": "prompt"}, q)
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
