"""Switching profiles with tabs across the top: no name popping up (idea 1114).

Build first (`./build.sh debug`), then, hidden and under the probe lock:
`lockf -t 900 /private/tmp/claude-501/search-probe.lock python3 Tests/profile_switch_name.py`.
Started hidden in a world of its own, never ordered onto a screen. With
spaces on and tabs across the top, a second profile is made (its first
space takes its name, as every new profile's does) and gone to and back,
from the badge's menu, in windows of their own and with profiles in one
window. The space's dot shows a space's name for a moment after you switch
spaces (SpaceDot.name); this checks what it showed on each switch, as the
bench records it on a test run.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("profile-switch-name")


def shown():
    return sv.cmd({"do": "profile"}).get("namesShown") or []


def head():
    """The merged window's one that isn't tucked: the one a key goes to."""
    return next(w["n"] for w in sv.cmd({"do": "windows"})["windows"] if not w.get("tucked") and w.get("open"))


def off_screen(t, label):
    up = [w for w in sv.cmd({"do": "windows"})["windows"] if w.get("shown")]
    t.ok(f"no window on screen ({label})", not up, up)
    if up:
        sv.quit()
        sys.exit("a window reached the screen: stopped")


def case(t, one_window):
    label = "one window" if one_window else "own windows"
    print(f"-- profiles in {label}")
    sv.quit()
    sv.setup(**{"spaces": True, "sidebar": False, "profiles.oneWindow": one_window})
    sv.launch()
    first = sv.cmd({"do": "profile"})["window"]
    sv.cmd({"do": "profile", "action": "new", "name": "Work"})
    sv.cmd({"do": "space", "action": "new", "name": "Errands"})
    time.sleep(0.8)
    before = len(shown())
    t.ok(f"[{label}] a space switch still names the space", "Errands" in shown(), shown())

    before = len(shown())
    sv.cmd({"do": "profile", "action": "window", "name": "Work"})
    time.sleep(1.2)
    off_screen(t, f"{label}, to Work")
    sv.cmd({"do": "profile", "action": "window", "name": first})
    time.sleep(1.2)
    off_screen(t, f"{label}, back")
    sv.cmd({"do": "profile", "action": "window", "name": "Work"})
    time.sleep(1.2)
    after = shown()[before:]
    t.ok(f"[{label}] switching profiles pops up no name", after == [], after)
    if one_window:
        # ⌃1–⌃9 through every profile's spaces: the first profile's home,
        # Work's (a profile's first space wears its name), and back.
        before = len(shown())
        for index in [1, 3, 2, 3, 1]:
            sv.cmd({"do": "space", "action": "go", "index": index, "window": head()})
            time.sleep(1.0)
        off_screen(t, f"{label}, by ⌃N")
        across = shown()[before:]
        t.ok(f"[{label}] ⌃N to another profile's space pops up no name", across == [], across)
        before = len(shown())
        sv.cmd({"do": "space", "action": "go", "index": 2, "window": head()})
        time.sleep(1.0)
        t.ok(f"[{label}] then ⌃N within the profile names the space", shown()[before:] == ["Errands"], shown()[before:])


def main():
    t = sv.T()
    try:
        case(t, False)
        case(t, True)
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
