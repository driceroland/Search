#!/usr/bin/env python3
"""The last tab across the top is never cut off (#1295), in a hidden probe.

Build first (`./build.sh debug`), then `python3 Tests/top_row_fit.py`.
The run of tabs is as wide as its tabs were worked out to be; a group's
heading is as wide as its name, measured by Search, and drawn by SwiftUI.
Where the two disagree, as another macOS's fonts can make them (reported
on macOS 15), the run came out short: its last tab cut off flat, its
cross out of reach, and no scrolling, as the row seemed to fit. Here the
headings are measured short on purpose (bench `headingShortfall`, 6 points
each), with pins, groups and loose tabs in the row, few and then many: the
run must hold every tab it lays out, or scroll. With nothing measured
short the run is exactly its tabs, as before.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("top-row-fit")


def run():
    time.sleep(0.8)
    return sv.cmd({"do": "probe"})["topRun"]


def main():
    t = sv.T()
    try:
        sv.setup(sidebar=False, **{"tabs.groups": True}); sv.launch()
        tabs = [sv.page(f"t{i}") for i in range(2)]
        sv.cmd({"do": "group", "id": tabs[0], "new": True, "name": "Reading list"})
        r = run()
        t.ok("measured right: the run is exactly its tabs, and doesn't scroll",
             abs(r["tabs"] - r["run"]) <= 1 and r["tabs"] > 0 and not r["scrolls"], r)

        # Measured short from here on, as on another macOS; a second group
        # is made and drawn with its heading measured so.
        sv.cmd({"do": "ui", "headingShortfall": 6})
        sv.cmd({"do": "group", "id": tabs[1], "new": True, "name": "Work things"})
        r = run()
        t.ok("headings measured short, a few tabs: the run still holds them all",
             r["run"] >= r["tabs"] - 0.5 and not r["scrolls"], r)

        for i in range(30):
            sv.sp("open", url=f"{sv.BASE}/more{i}")
        r = run()
        t.ok("headings measured short, the row full: the run is narrower only because it scrolls",
             r["run"] < r["tabs"] and r["scrolls"], r)
        sv.cmd({"do": "ui", "headingShortfall": 0})
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
