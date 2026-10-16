"""New tabs at the end of the list (Settings › Tabs › Open new tabs at the end).

Build first (`./build.sh`), then `python3 Tests/new_tab_end.py`. Hidden.
"""
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("new-tab-end")


def order():
    return [x["id"] for x in sv.sp("state")["tabs"] if not x.get("blank")]


def run(t, at_end):
    sv.setup(sidebar=True)
    if at_end: subprocess.run(["defaults", "write", sv.SUITE, "tabs.newPlace", "end"])
    sv.launch()
    try:
        a = sv.page("a")
        sv.page("b")
        sv.page("c")
        sv.cmd({"do": "select", "id": a}); time.sleep(0.5)
        d = sv.page("d")
        now = order()
        if at_end:
            t.ok("switched on, a new tab goes to the end", now[-1] == d, now)
        else:
            t.ok("switched off, a new tab goes just after the one you're on", now.index(d) == now.index(a) + 1, now)
    finally:
        sv.finish()


def main():
    t = sv.T()
    try:
        run(t, False)
        run(t, True)
    finally:
        t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
