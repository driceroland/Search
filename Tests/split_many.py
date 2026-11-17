#!/usr/bin/env python3
"""Split View with three and four pages, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/split_many.py`. Uses the split
suite's harness: hidden, nothing shown, everything removed afterwards.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("split-many")
t = sv.T()
try:
    sv.setup(splitView=True); sv.launch()
    a = sv.page("a"); b = sv.page("b"); c = sv.page("c"); d = sv.page("d"); e = sv.page("e")
    sv.sp("pair", id=b, **{"with": a}, side="right")
    st = sv.sp("pair", id=c, **{"with": b}, side="right")
    p = st["splits"][0] if st.get("splits") else {}
    t.ok("three: one split [a, b, c]", len(st.get("splits", [])) == 1 and p.get("tabs") == [a, b, c], st.get("splits"))
    t.ok("three: even thirds", p.get("sizes") and all(abs(x - 1 / 3) < 0.02 for x in p["sizes"]), p.get("sizes"))
    st = sv.sp("pair", id=d, **{"with": c}, side="right")
    p = st["splits"][0]
    t.ok("four: [a, b, c, d]", p.get("tabs") == [a, b, c, d], p)
    t.ok("four: no room for a fifth", st.get("canAddPane") is False, st.get("canAddPane"))
    st = sv.sp("pair", id=e, **{"with": d}, side="right")
    t.ok("a fifth is refused, the split unchanged", st["splits"][0]["tabs"] == [a, b, c, d], st["splits"])
    sv.sp("save"); sv.quit(); sv.launch(); time.sleep(1)
    st = sv.sp("state")
    t.ok("relaunch: four pages back together", any(len(s["tabs"]) == 4 for s in st.get("splits", [])), st.get("splits"))
    four = next((s["tabs"] for s in st.get("splits", []) if len(s["tabs"]) == 4), [a, b, c, d])
    a, b, c, d = four  # a relaunch gives the tabs new ids
    st = sv.sp("leave", id=b)
    p = st["splits"][0] if st.get("splits") else {}
    t.ok("leave b: [a, c, d] stay together", p.get("tabs") == [a, c, d], st.get("splits"))
    sv.sp("leave", id=c); st = sv.sp("leave", id=d)
    t.ok("down to one page: no split left", not st.get("splits"), st.get("splits"))
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
