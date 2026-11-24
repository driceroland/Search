#!/usr/bin/env python3
"""Settings › Tabs › In the tab bar › "Clicking the tab you're on keeps its
name" (idea 1076), in a hidden probe.

Build first (`./build.sh debug`), then `python3 Tests/tab_click_keeps_name.py`.
On, with Always show the address bar on: a click on the tab you're on leaves
the tab as it is, no field in it and no site card; Site Information… still
opens the address with its card. On without the address bar, or off: the
click opens the address in the tab, as before. In the column and across the
top. Nothing is put on a screen.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("tab-keeps-name")


def state():
    p = sv.cmd({"do": "probe"})
    return {"card": p["siteCard"], "editing": p["tabEditing"] != ""}


def run(t, sidebar, bar, keeps):
    sv.setup(**{"sidebar": sidebar, "address.shown": bar, "tabs.clickKeepsName": keeps})
    sv.launch()
    sv.page("first")
    label = f"{'column' if sidebar else 'top row'}, address bar {'on' if bar else 'off'}, setting {'on' if keeps else 'off'}"
    quiet = keeps and bar
    sv.cmd({"do": "ui", "opentab": True}); time.sleep(0.9)
    click = state()
    if quiet:
        t.ok(f"{label}: a click on the tab keeps its name", not click["editing"] and not click["card"], click)
    else:
        t.ok(f"{label}: a click on the tab opens its address", click["editing"], click)
    sv.cmd({"do": "ui", "finishedit": True}); time.sleep(0.5)
    sv.cmd({"do": "ui", "siteinfo": True}); time.sleep(0.9)
    info = state()
    t.ok(f"{label}: Site Information… still shows the card", info["card"] and info["editing"], info)
    sv.cmd({"do": "ui", "finishedit": True}); time.sleep(0.5)
    sv.quit()


def main():
    t = sv.T()
    try:
        run(t, True, True, True)
        run(t, False, True, True)
        run(t, True, False, True)
        run(t, True, True, False)
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
