#!/usr/bin/env python3
"""Settings › Tabs › In the tab bar › "Double click to rename", in a hidden
probe.

Build first (`./build.sh debug`), then `python3 Tests/tab_click_renames.py`.
On: a click on the tab you're on opens its name to type over, no site card,
even with "Clicking the tab you're on keeps its name" on too; Site
Information… still opens the address with its card. Off: the click opens the
address, as before. In the column, across the top, and in the column of icons,
where there is no title and the click still opens the address.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("tab-click-renames")


def state():
    p = sv.cmd({"do": "probe"})
    return {"card": p["siteCard"], "editing": p["tabEditing"] != "", "renaming": p["tabRenaming"]}


def run(t, sidebar, renames, keeps=False, icons=False):
    sv.setup(**{"sidebar": sidebar, "sidebar.icons": icons, "address.shown": keeps,
                "tabs.clickKeepsName": keeps, "tabs.clickRenames": renames})
    sv.launch()
    sv.page("first")
    label = f"{'column' if sidebar else 'top row'}{' of icons' if icons else ''}, renames {'on' if renames else 'off'}, keeps name {'on' if keeps else 'off'}"
    sv.cmd({"do": "ui", "opentab": True}); time.sleep(0.9)
    click = state()
    if renames and not icons:
        t.ok(f"{label}: a click renames the tab", click["editing"] and click["renaming"] and not click["card"], click)
    elif icons:
        t.ok(f"{label}: a click doesn't rename", not click["renaming"], click)
    else:
        t.ok(f"{label}: a click opens its address", click["editing"] and not click["renaming"], click)
    sv.cmd({"do": "ui", "finishedit": True}); time.sleep(0.5)
    if not icons:
        sv.cmd({"do": "ui", "siteinfo": True}); time.sleep(0.9)
        info = state()
        t.ok(f"{label}: Site Information… still shows the address and card", info["card"] and info["editing"] and not info["renaming"], info)
        sv.cmd({"do": "ui", "finishedit": True}); time.sleep(0.5)
    sv.quit()


def main():
    t = sv.T()
    try:
        run(t, True, True)
        run(t, False, True)
        run(t, True, True, keeps=True)
        run(t, True, False)
        run(t, True, True, icons=True)
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
