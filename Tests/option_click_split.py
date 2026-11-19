#!/usr/bin/env python3
"""⌥-click on a link opens it in Split View, with the setting on, in a hidden
probe.

Build first (`./build.sh debug`), then `python3 Tests/option_click_split.py`.
Real clicks with the keys held (the bench's tap), so WebKit hands Search the
link as it does for a hand; no window is made or shown. Off, the default, a
⌥-click follows the link as before. On, it opens beside the page as the
link's Open Link in Split View does, and ⌥ with ⇧ or ⌘ stays a peek's or a
⌘-click's.
"""
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("option-split")

LINK = ("document.body.innerHTML = '<a id=\"l\" href=\"{}\" style=\"display:block;"
        "font-size:60px;line-height:120px;padding:0 20px\">a link</a>'; true")


def click(tab, path, mods):
    """The link to `path` put on the page, then clicked with `mods` held →
    the state after."""
    sv.sp("select", id=tab); time.sleep(0.4)
    sv.ev(tab, LINK.format(f"{sv.BASE}/{path}")); time.sleep(0.3)
    sv.cmd({"do": "tap", "id": tab, "selector": "#l", "mods": mods}); time.sleep(1.5)
    return sv.sp("state")


def opened(st, path): return [x["id"] for x in st["tabs"] if x["url"].endswith("/" + path)]


def paired(st, a, b): return any(s["tabs"] == [a, b] for s in st["splits"])


def main():
    t = sv.T()
    try:
        sv.setup(); sv.launch()
        found = sv.cmd({"do": "settings", "find": "option click split"})["found"]
        t.ok("Settings finds ⌥-click a link opens it in Split View",
             any("links.optionSplit" in i["keys"] for i in found), [i["id"] for i in found])
        stored = subprocess.run(["defaults", "read", sv.SUITE, "links.optionSplit"], capture_output=True, text=True)
        t.ok("off by default: nothing written", stored.returncode != 0, stored.stdout)
        a = sv.page("a")
        st = click(a, "followed", ["opt"])
        t.ok("off: ⌥-click follows the link in the same tab", sv.url(st, a).endswith("/followed"), sv.url(st, a))
        t.ok("off: no tab opens beside it", not st["splits"] and len(opened(st, "followed")) == 1, st["splits"])
    finally:
        sv.finish()
    try:
        sv.setup(**{"links.optionSplit": True}); sv.launch()
        a = sv.page("a"); sv.page("b")
        st = click(a, "beside", ["opt"])
        new = opened(st, "beside")
        t.ok("on: ⌥-click opens one new tab for the link", len(new) == 1 and new[0] != a, st["tabs"])
        t.ok("…in a pair with the page it came from, on its right", bool(new) and paired(st, a, new[0]), st["splits"])
        t.ok("…with the keys", bool(new) and st["activeID"] == new[0], st["activeID"])
        t.ok("…and the page it came from stays where it was", sv.url(st, a).endswith("/a"), sv.url(st, a))
        # Modifiers that already mean something keep it.
        c = sv.page("c")
        st = click(c, "optshift", ["opt", "shift"])
        t.ok("⌥⇧-click is not a split (peek stays on ⇧)", not any(c in s["tabs"] for s in st["splits"]), st["splits"])
        d = sv.page("d")
        before = {x["id"] for x in sv.sp("state")["tabs"]}
        st = click(d, "optcmd", ["opt", "cmd"])
        new = [x for x in opened(st, "optcmd") if x not in before]
        t.ok("⌥⌘-click opens a tab as a ⌘-click does, not a split",
             len(new) == 1 and not any(d in s["tabs"] for s in st["splits"]), (new, st["splits"]))
        e = sv.page("e")
        st = click(e, "peeked", ["shift"])
        p = sv.cmd({"do": "probe"})
        t.ok("⇧-click is still a peek", p.get("peek", "").endswith("/peeked") and not any(e in s["tabs"] for s in st["splits"]),
             (p.get("peek"), st["splits"]))
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
