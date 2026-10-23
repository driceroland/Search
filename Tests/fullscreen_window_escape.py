#!/usr/bin/env python3
"""Escape twice to leave the WINDOW's own full screen (the green button,
⌃⌘F), as in Arc, in a real full screen.

Build first (`./build.sh`), then `python3 Tests/fullscreen_window_escape.py`.
Unlike the other suites this one takes the screen: a hidden test run can't
go full screen, so this world is started with its windows shown
(SEARCH_PROBE_SHOWN) and `windowfull` puts its window into macOS full screen
for real, several times, for a few seconds each. With the switch off one
Escape takes the window out (fab's report, 23 Oct 2026); with it on the
first only puts the reminder up, a second within two seconds leaves, a
slower one doesn't, a held key never does, and Search's own Escape jobs (the
find bar) still go first without counting.
"""
import sys, time, subprocess, os
from pathlib import Path
REPO = str(Path(__file__).resolve().parents[1])
sys.path.insert(0, f"{REPO}/Tests")
import split_view as sv
sv.use("fullscreen-window-escape")
ESC = "\u001b"
def probe(): p = sv.cmd({"do": "probe"}); return {"full": p.get("windowFullScreen"), "reminder": p.get("escapeReminder")}
def esc(held=False): sv.cmd({"do": "press", "code": 53, "chars": ESC, "mods": ["repeat"] if held else []})
def full(on): return sv.cmd({"do": "windowfull", "on": on}).get("windowFullScreen")
def launch_shown():
    if os.path.exists(sv.SOCK): os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_PROBE_SHOWN=1", sv.APP])
    for _ in range(150):
        if os.path.exists(sv.SOCK): break
        time.sleep(0.1)
    time.sleep(2.5)
    sv.started.update((sv.running() - before) & sv.holding())
t = sv.T()
try:
    # Control: with the switch off, one Escape takes the window out (what fab sees today).
    sv.setup(**{"sidebar": True, "fullscreen.escapeTwice": False}); launch_shown()
    a = sv.page("a"); sv.cmd({"do": "select", "id": a}); time.sleep(1)
    sv.cmd({"do": "key", "id": a, "text": "x"}); time.sleep(0.3)
    t.ok("switch off: window goes full screen", full(True) is True)
    esc(); time.sleep(1.8); s = probe()
    t.ok("switch off: ONE Escape takes the window out (fab's bug)", s["full"] is False, s)
    sv.quit(); time.sleep(1)

    # The fix: switch on (fab's build's default).
    sv.setup(**{"sidebar": True, "fullscreen.escapeTwice": True}); launch_shown()
    a = sv.page("a"); sv.cmd({"do": "select", "id": a}); time.sleep(1)
    sv.cmd({"do": "key", "id": a, "text": "x"}); time.sleep(0.3)
    t.ok("window goes full screen", full(True) is True)
    esc(); time.sleep(0.6); s = probe()
    t.ok("first Escape: still full screen, reminder up", s["full"] is True and s["reminder"] is True, s)
    esc(); time.sleep(1.8); s = probe()
    t.ok("quick second Escape: out of full screen, reminder gone", s["full"] is False and s["reminder"] is False, s)

    t.ok("full screen again", full(True) is True)
    esc(); time.sleep(2.6); s = probe()
    t.ok("2.6 s after one press: still full screen, reminder gone by itself", s["full"] is True and s["reminder"] is False, s)
    esc(); time.sleep(0.6); s = probe()
    t.ok("a press after the wait is a first again: still full screen", s["full"] is True and s["reminder"] is True, s)
    esc(); time.sleep(1.8); s = probe()
    t.ok("then a quick second: out", s["full"] is False, s)

    t.ok("full screen a third time", full(True) is True)
    esc(); time.sleep(0.3)
    for _ in range(5): esc(held=True)
    time.sleep(1.5); s = probe()
    t.ok("Escape held down: still full screen", s["full"] is True, s)
    time.sleep(1.0)
    esc(); time.sleep(0.4); esc(); time.sleep(1.8); s = probe()
    t.ok("quick double press after letting go: out", s["full"] is False, s)

    t.ok("full screen a fourth time", full(True) is True)
    sv.cmd({"do": "find", "text": "a"}); time.sleep(0.6)
    st = sv.sp("state"); t.ok("find bar open", st.get("finding") is True, st)
    esc(); time.sleep(0.6); s = probe(); st = sv.sp("state")
    t.ok("Escape with the find bar open closes it and doesn't count", st.get("finding") is False and s["full"] is True and s["reminder"] is False, (s, st))
    esc(); time.sleep(0.4); esc(); time.sleep(1.8); s = probe()
    t.ok("then a quick double press: out", s["full"] is False, s)
finally:
    try: full(False)
    except Exception: pass
    sv.quit(); time.sleep(1); t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
