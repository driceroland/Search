#!/usr/bin/env python3
"""The swipe back goes only when it is meant (#1389), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/swipe_intent.py`. It uses
the split suite's harness: started hidden, no window made or shown,
everything removed afterwards. The Mac's Swipe between pages is stood in for
with `ui swipepages on`.

- A fast flick down, let go, then a gesture that sets off a little more
  sideways than down while the page still glides: scrolling going on, not a
  swipe. The same gesture with the page at rest still goes back, and a
  plainly sideways one goes back even mid-glide.
- Pulled well past the point where letting go goes back, then drawn back a
  little: letting go stays on the page. Pulled out and let go there still goes.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("swipe-intent")

t = sv.T()
def page(r): return r.rsplit("/", 1)[-1]
def pull(dx, **more): return sv.cmd({"do": "pull", "dx": dx, "steps": 12, "ms": 240, **more})
def go(id, name): sv.cmd({"do": "go", "id": id, "url": f"{sv.BASE}/{name}"}); sv.cmd({"do": "wait", "id": id, "seconds": 5})

try:
    sv.setup(); sv.launch()
    tab = sv.page("long"); sv.cmd({"do": "select", "id": tab}); sv.cmd({"do": "wait", "id": tab, "seconds": 5})
    sv.cmd({"do": "ui", "swipepages": True}); time.sleep(0.3)

    def check(name, expect_back, dx, **more):
        go(tab, "long?b")
        time.sleep(0.6)
        r = pull(dx, **more)
        went = page(r["after"]) == "long" and page(r["before"]) == "long?b"
        t.ok(name, went == expect_back, r)

    # Sanity: a plain swipe goes back.
    check("a plain swipe goes back", True, 200)
    # A gesture 2:1 sideways at rest is a swipe...
    check("at rest, a gesture twice as sideways as down goes back", True, 200, dy=100)
    # ...but straight after a flick down, with its glide going, it is scrolling.
    check("mid-glide after a flick down, the same gesture stays", False, 200, dy=100, down=400)
    check("mid-glide, a quick short flick sideways stays too", False, 40, dy=10, down=400)
    # A plainly sideways one still goes mid-glide.
    check("mid-glide, a plainly sideways gesture still goes back", True, 200, down=400)
    # Pulled out and drawn back a little: letting go stays.
    check("pulled to 200 and drawn back 30, letting go stays", False, 200, back=30)
    check("pulled to 200 and drawn back 10, letting go still goes", True, 200, back=10)
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
