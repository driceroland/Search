"""Arc's spaces brought over show at once, with no Spaces off and on (idea 1109).

Build first (`./build.sh`), then `python3 Tests/arc_spaces_show.py`. The
made-up Arc profile of spaces_quit_keep.py (two spaces, Work and Study, a
synthetic StorableSidebar.json, never anyone's real Arc data) is brought
into a fresh hidden probe, in both orders a person can take:

- Settings › Spaces & Pins › Bring Arc's spaces and pins over, then Set Up
  Like Arc (offered under what came);
- Set Up Like Arc first (Settings, or the welcome's "Coming from Arc?"),
  then Arc's spaces brought over.

Either way the space not on screen is made ahead of time, its tabs there
for the swipe and the map to draw, as after a launch; before the fix it was
empty until Spaces was turned off and on.

Nothing here makes, shows or brings forward a window.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402
import spaces_quit_keep as keep  # noqa: E402

sv.use("arc-spaces-show")


def parked(st):
    return {k: v for row in st["parked"] for k, v in row.items()}


def run(t, order):
    sv.setup(**{"start.fresh": False})
    keep.arc()
    sv.launch()
    for step in order:
        if step == "import":
            out = sv.cmd({"do": "import", "from": "Arc", "what": ["spaces"]}).get("arc") or {}
            t.ok(f"{' then '.join(order)}: Arc's two spaces came in", out.get("names") == ["Work", "Study"], out)
        else:
            v = sv.cmd({"do": "settings", "set": "arc.setup", "value": True}).get("values", {})
            t.ok(f"{' then '.join(order)}: set up like Arc", v.get("arc") is True, v.get("arc"))
        time.sleep(1.2)
    st = sv.cmd({"do": "space"})
    study = keep.ids()["Study"]
    t.ok(f"{' then '.join(order)}: Spaces on, Work on screen", st["on"] and st["current"] == "Work", (st["on"], st["current"]))
    t.ok(f"{' then '.join(order)}: Study's row is there beside it, with its tabs, no toggle",
         parked(st).get(study, 0) > 0, st["parked"])
    sv.cmd({"do": "space", "action": "go", "index": 2})
    time.sleep(1)
    st = sv.cmd({"do": "space"})
    t.ok(f"{' then '.join(order)}: ⌃2 brings Study with its tabs", st["current"] == "Study" and st["tabs"] > 0,
         (st["current"], st["tabs"]))
    sv.quit()


def main():
    t = sv.T()
    try:
        run(t, ["import", "setup"])
        run(t, ["setup", "import"])
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


main()
