#!/usr/bin/env python3
"""Settings › Tabs › In the tab bar › "Clicking the tab you're on edits its
address only" (idea 951), in a hidden probe.

Build first (`./build.sh debug`), then `python3 Tests/site_card_click.py`.
Off, as it starts: a click on the tab you're on opens its address with the
site card under it, as before. On: the address opens, to edit, and no card
comes; the tab's menu › Site Information… still brings the card. In the
row across the top and in the column. The card is a child window of the
hidden probe's window, never on a screen.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("site-card-click")


def state():
    p = sv.cmd({"do": "probe"})
    return {"card": p["siteCard"], "editing": p["tabEditing"] != ""}


def run(t, name, sidebar, only):
    prefs = {"sidebar": sidebar}
    if only is not None: prefs["tabs.clickAddressOnly"] = only
    sv.setup(**prefs); sv.launch()
    sv.page("first")
    label = f"{name}, setting {'on' if only else 'off' if only is False else 'untouched'}"
    sv.cmd({"do": "ui", "opentab": True}); time.sleep(0.9)
    click = state()
    t.ok(f"{label}: a click on the tab opens its address", click["editing"], click)
    t.ok(f"{label}: the card {'stays away' if only else 'comes up'}", click["card"] == (not only), click)
    sv.cmd({"do": "ui", "finishedit": True}); time.sleep(0.5)
    gone = state()
    t.ok(f"{label}: nothing left up after the edit", not gone["editing"] and not gone["card"], gone)
    sv.cmd({"do": "ui", "siteinfo": True}); time.sleep(0.9)
    info = state()
    t.ok(f"{label}: Site Information… shows the card", info["card"] and info["editing"], info)
    sv.cmd({"do": "ui", "finishedit": True}); time.sleep(0.5)
    sv.quit()


def main():
    t = sv.T()
    try:
        run(t, "top row", False, None)
        run(t, "top row", False, True)
        run(t, "column", True, True)
        run(t, "top row", False, False)
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
