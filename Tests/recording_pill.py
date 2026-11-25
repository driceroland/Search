#!/usr/bin/env python3
"""The recording pill (RecordingIndicator.swift), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/recording_pill.py`. The pill's
model is exercised through ./bench as ExtensionCapture drives it; the pill
itself never reaches a screen in a test run, which is checked too.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402


def pill(action="state", **fields):
    return sv.cmd({"do": "recording", "action": action, **fields})


def main():
    t = sv.T()
    try:
        sv.setup(); sv.launch()
        a = sv.page("recorder"); b = sv.page("other")
        s = pill("show", id=a, names=["Loom"], what="is recording your screen")
        t.ok("a line for the extension recording", s["lines"] == [["loom", "Loom", "is recording your screen"]], s["lines"])
        t.ok("the tab capturing wears the mark", s["recordingTabs"] == [a], s["recordingTabs"])
        t.ok("a test run never puts the pill on a screen", s["onScreen"] is False)
        s = pill("show", id=a, names=["Loom", "Tella"], what="is using your camera and microphone")
        t.ok("one line per extension", [l[1] for l in s["lines"]] == ["Loom", "Tella"], s["lines"])
        s = pill("stop", name="tella")
        t.ok("Stop asks for that extension to stop", s["stopped"] == "tella", s)
        s = pill("clear")
        t.ok("nothing recording: no line, no mark", s["lines"] == [] and s["recordingTabs"] == [], s)
        # ✕ hides a site's share from the pill only; it never stops anything.
        s = pill("show", id=a, names=["Meet"], what="is sharing your screen", site=True)
        s = pill("dismiss", name="meet")
        t.ok("✕ hides the line, the share is still live", s["shown"] == [] and len(s["lines"]) == 1, s)
        t.ok("…and stops nothing", pill("state")["recordingTabs"] == [a])
        s = pill("show", id=a, names=["Meet"], what="is sharing your screen", site=True)
        t.ok("the same share updating stays hidden", s["shown"] == [], s)
        pill("clear")
        s = pill("show", id=a, names=["Meet"], what="is sharing your screen", site=True)
        t.ok("a new share shows the pill again", s["shown"] == ["meet"], s)
        pill("clear")
        pill("show", id=a, names=["Loom"], what="is recording your screen")
        s = pill("dismiss", name="loom")
        t.ok("an extension's recording can't be dismissed", s["shown"] == ["loom"], s)
        pill("clear")
        sv.sp("select", id=a); time.sleep(0.4)
        s = pill("host", id=b)
        t.ok("a page lent to the pill", s["hosted"] is True, s)
        s = pill("release", id=b)
        t.ok("…and given back where it was", s["hosted"] is False and s["backHome"] is True, s)
        t.ok("still never on a screen", pill()["onScreen"] is False)
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
