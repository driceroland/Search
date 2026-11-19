#!/usr/bin/env python3
"""Two fingers spread on a peek open it as a tab.

Build first (`./build.sh`), then `python3 Tests/peek_pinch.py`. It uses the
split suite's harness: started hidden, no window shown, everything removed
afterwards. The pinch is handed to the peek's page in steps, as a
trackpad's magnify events would bring it (bench "peek" "pinch").
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("peek-pinch")


def peek(page):
    sv.cmd({"do": "peek", "url": f"{sv.BASE}/{page}"})
    time.sleep(1.2)


def main():
    t = sv.T()
    try:
        sv.setup(sidebar=True)
        sv.launch()
        sv.page("a")
        n = len(sv.sp("state")["tabs"])

        peek("b")
        r = sv.cmd({"do": "peek", "pinch": [0.05, 0.05, 0.05]})
        t.ok("a small spread grows the panel without opening it", 0 < r.get("pinch", 0) < 1, r)
        t.ok("…and leaves the peek up when the fingers lift", r.get("peek", "").endswith("/b"), r)
        t.ok("…no tab more", len(sv.sp("state")["tabs"]) == n)

        r = sv.cmd({"do": "peek", "pinch": [0.1, 0.1, 0.1, 0.1], "cancel": True})
        t.ok("cancelled past the line: still a peek", r.get("peek", "").endswith("/b"), r)

        r = sv.cmd({"do": "peek", "pinch": [0.1, 0.1, 0.1, 0.1]})
        t.ok("spread past the line: the panel grows to the page first", r.get("peek", "").endswith("/b"), r)
        time.sleep(0.8)
        s = sv.sp("state")
        t.ok("…then the peek is gone", sv.cmd({"do": "probe"}).get("peek", "") == "")
        t.ok("…kept as a tab", len(s["tabs"]) == n + 1, len(s["tabs"]))
        front = next(x for x in s["tabs"] if x["id"] == s["activeID"])
        t.ok("…and it is the one in front", front["url"].endswith("/b"), front["url"])

        try:
            sv.cmd({"do": "peek", "pinch": [0.5]})
            refused = False
        except RuntimeError as e:
            refused = "no peek" in str(e)
        t.ok("no peek up: the pinch isn't taken", refused)
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
