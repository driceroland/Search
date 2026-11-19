#!/usr/bin/env python3
"""View › Actual Size names the zoom it goes to when Settings › Browsing ›
Pages › Page zoom isn't 100% (#1210), and follows the setting live.

Build first (`./build.sh debug`), then `python3 Tests/actual_size_title.py`.
A hidden probe reads the View menu through Bench "menus"; no window is shown.
"""
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("actual-size-title")


def view():
    time.sleep(0.4)
    return [i for i in sv.cmd({"do": "menus"})["menus"].get("View", []) if i.startswith("Actual Size")]


if __name__ == "__main__":
    t = sv.T()
    try:
        sv.setup()
        subprocess.run(["defaults", "write", sv.SUITE, "pageZoom", "-float", "0.95"])
        sv.launch()
        time.sleep(1.0)
        items = view()
        t.ok("at 95%: Actual Size (95%)", items == ["Actual Size (95%)"], items)
        sv.cmd({"do": "ui", "pageZoom": 1.25})
        items = view()
        t.ok("changed live to 125%: Actual Size (125%)", items == ["Actual Size (125%)"], items)
        sv.cmd({"do": "ui", "pageZoom": 1.0})
        items = view()
        t.ok("at 100%: plain Actual Size", items == ["Actual Size"], items)
    finally:
        sv.finish()
        t.done()
    sys.exit(1 if t.failed else 0)
