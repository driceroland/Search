#!/usr/bin/env python3
"""What decides whether the page in front counts as seen and focused
(idea 949), on Search's side, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/page_activity.py`.
A site that marks a message read when it is seen (Instagram's direct
messages) asks the page whether it is visible and focused. WebKit answers
from the page's view: in a visible, uncovered window, not hidden, and, for
focus, holding the keys in the key window. Checked here, in the row across
the top and in the column, as launched, after going to another tab and
back, and after a click into the page: the page in front is in the
browser's own window, neither it nor a view around it is hidden, it holds
the keys, and no other web view holds a copy of it.

What the page itself says here — hidden, not focused, no animation frames
— is the probe's doing: the app is hidden and its window is off every
screen and never key. Printed, not checked.
"""
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("page-activity")

PAGE = "JSON.stringify({vis: document.visibilityState, focus: document.hasFocus()})"


def check(t, label, page):
    a = sv.cmd({"do": "probe"})["pageActivity"]
    print(f"  {label}: page says {sv.ev(page, PAGE)}; app {json.dumps(a, sort_keys=True)}")
    t.ok(f"{label}: in the browser's window", a["inBrowserWindow"], a)
    t.ok(f"{label}: not hidden", not a["pageHidden"] and a["alpha"] == 1, a)
    t.ok(f"{label}: holds the keys", a["hasKeys"], a)
    t.ok(f"{label}: no copy of it elsewhere", a["copies"] == [], a)


def run(t, name, sidebar):
    sv.setup(sidebar=sidebar); sv.launch()
    a = sv.page("message")
    b = sv.page("other")
    sv.sp("select", id=a); time.sleep(0.8)
    check(t, f"{name}, in front", a)
    sv.sp("select", id=b); time.sleep(0.8)
    sv.sp("select", id=a); time.sleep(0.8)
    check(t, f"{name}, back from another tab", a)
    sv.ev(a, "document.body.insertAdjacentHTML('beforeend', '<div id=box style=\"width:200px;height:200px\"></div>'), 1")
    sv.cmd({"do": "tap", "id": a, "selector": "#box"}); time.sleep(0.6)
    check(t, f"{name}, after a click into it", a)
    sv.quit()


def main():
    t = sv.T()
    try:
        run(t, "top row", False)
        run(t, "column", True)
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
