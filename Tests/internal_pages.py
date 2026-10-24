#!/usr/bin/env python3
"""Settings, History, Downloads, Bookmarks, Passwords, Bring Things Over and
the release notes are tabs of their own (InternalPages.swift), checked in a
hidden probe.

Build first (`./build.sh`), then `python3 Tests/internal_pages.py`. It uses
split_view.py's harness in a world of its own (bld-pages-<checkout>): started
hidden, driven through ./bench's socket, everything removed afterwards.
Nothing here makes, shows or brings forward a window. Keys are pressed
through the app's event queue, as a hand's reach its shortcuts.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bld-pages")

COMMA, Y, J, W, N, LBRACKET, RBRACKET = 43, 16, 38, 13, 45, 33, 30


def press(code, chars, *mods):
    sv.cmd({"do": "press", "code": code, "chars": chars, "mods": list(mods)}); time.sleep(0.6)


def st(): return sv.sp("state")
def tabs(): return st()["tabs"]
def active(): return st()["activeID"]
def kind(x): return x["internal"].split("://", 1)[1].split("/", 1)[0] if x["internal"] else ""
def of(k): return [x for x in tabs() if kind(x) == k]
def one(id): return next(x for x in tabs() if x["id"] == id)


def case_open_focus(t):
    """⌘, ⌘Y ⇧⌘J open tabs, and focus the one already open"""
    sv.setup(); sv.launch()
    a = sv.page("a"); b = sv.page("b")
    press(COMMA, ",", "cmd")
    s = of("settings")
    t.ok("⌘, opens one Settings tab", len(s) == 1, [x["internal"] for x in tabs()])
    t.ok("…in front", s and active() == s[0]["id"], (active(), s))
    t.ok("…with no web view behind it", s and not s[0]["built"] and not s[0]["blank"], s)
    t.ok("…with an address of its own", s and s[0]["internal"].startswith("search://settings"), s)
    t.ok("the probe still says Settings is up", sv.cmd({"do": "probe"}).get("settings") is True)
    settings = s[0]["id"]
    sv.sp("select", id=a); time.sleep(0.5)
    count = len(tabs())
    press(COMMA, ",", "cmd")
    t.ok("⌘, again: the same tab, brought forward", active() == settings and len(of("settings")) == 1 and len(tabs()) == count,
         (active(), settings, len(tabs()), count))
    press(COMMA, ",", "cmd")
    t.ok("⌘, on Settings leaves it open", active() == settings and len(of("settings")) == 1)
    press(Y, "y", "cmd")
    h = of("history")
    t.ok("⌘Y opens History in a tab", len(h) == 1 and active() == h[0]["id"], [x["internal"] for x in tabs()])
    press(J, "j", "cmd", "shift")
    d = of("downloads")
    t.ok("⇧⌘J opens Downloads in a tab", len(d) == 1 and active() == d[0]["id"])
    for k in ["bookmarks", "passwords"]:
        sv.cmd({"do": "ui", k: True}); time.sleep(0.5)
        t.ok(f"{k} opens in a tab of its own", len(of(k)) == 1 and active() == of(k)[0]["id"], [x["internal"] for x in tabs()])
    sv.cmd({"do": "ui", "import": "on"}); time.sleep(0.5)
    t.ok("Bring Things Over opens in a tab", len(of("import")) == 1 and active() == of("import")[0]["id"])
    sv.cmd({"do": "ui", "show": "search://settings/privacy"}); time.sleep(0.6)
    s = of("settings")
    t.ok("search://settings/privacy goes to the open Settings tab, at Privacy",
         len(s) == 1 and active() == s[0]["id"] and s[0]["internal"] == "search://settings/privacy", s)
    # ⌘W closes the tab in front, and only it.
    before = [x["id"] for x in tabs()]
    press(W, "w", "cmd")
    after = [x["id"] for x in tabs()]
    t.ok("⌘W closes the Settings tab like any tab", s and s[0]["id"] not in after and len(after) == len(before) - 1, (before, after))
    t.ok("…and the web pages stay", a in after and b in after)


def case_blank_and_private(t):
    """an empty tab becomes the page; a private one doesn't"""
    sv.setup(); sv.launch()
    blank = active()
    t.ok("starts on an empty tab", one(blank)["blank"], tabs())
    press(COMMA, ",", "cmd")
    t.ok("⌘, on an empty tab: that tab becomes Settings", len(tabs()) == 1 and one(blank)["internal"].startswith("search://settings"), tabs())
    sv.sp("private"); time.sleep(0.5)
    shy = active()
    t.ok("a private tab in front", one(shy)["shy"] and one(shy)["blank"])
    sv.cmd({"do": "ui", "settings": False}); time.sleep(0.5)
    t.ok("Settings put away from the bench", not of("settings"))
    press(COMMA, ",", "cmd")
    s = of("settings")
    t.ok("⌘, from a private tab: Settings opens beside it, not private",
         len(s) == 1 and not s[0]["shy"] and active() == s[0]["id"], s)
    t.ok("…and the private tab is still there, still private", any(x["id"] == shy and x["shy"] and x["blank"] for x in tabs()))


def case_back_forward(t):
    """from one page to another and back, and onto the web and back"""
    sv.setup(); sv.launch()
    sv.page("a")
    press(Y, "y", "cmd")
    h = of("history")[0]["id"]
    sv.cmd({"do": "ui", "show": "search://downloads"}); time.sleep(0.5)
    d = of("downloads")[0]["id"]
    t.ok("a third kind: a tab of its own", d != h)
    # In-page links: Settings › Passwords… goes in the same tab (lead).
    sv.cmd({"do": "ui", "settings": True}); time.sleep(0.5)
    s = of("settings")[0]["id"]
    sv.cmd({"do": "ui", "lead": "passwords"}); time.sleep(0.5)
    t.ok("Settings › Passwords…: the same tab goes to Passwords", one(s)["internal"] == "search://passwords" and not of("settings"), one(s))
    t.ok("…and can go back", one(s)["canBack"])
    press(LBRACKET, "[", "cmd")
    t.ok("⌘[ comes back to Settings", one(s)["internal"].startswith("search://settings"), one(s))
    t.ok("…and can go forward", one(s)["canForward"])
    press(RBRACKET, "]", "cmd")
    t.ok("⌘] goes to Passwords again", one(s)["internal"] == "search://passwords")
    press(LBRACKET, "[", "cmd")
    # Onto the web from Settings, as a typed address does, then Back.
    sv.cmd({"do": "ui", "go": f"{sv.BASE}/web"}); time.sleep(1.2)
    x = one(s)
    t.ok("an address from Settings loads in its tab", x["url"].endswith("/web") and not x["internal"], x)
    t.ok("…which can go back", x["canBack"])
    press(LBRACKET, "[", "cmd")
    x = one(s)
    t.ok("Back from the first web page: Settings again, the web view let go",
         x["internal"].startswith("search://settings") and not x["built"], x)


def case_restore(t):
    """kept in the session, back after a relaunch"""
    sv.setup(); sv.launch()
    sv.page("a")
    sv.cmd({"do": "ui", "show": "search://settings/privacy"}); time.sleep(0.6)
    sv.cmd({"do": "ui", "history": True}); time.sleep(0.6)
    sv.quit(); time.sleep(1)
    urls = [e["url"] for e in sv.session()["tabs"]]
    t.ok("the session keeps them by address", "search://settings/privacy" in urls and "search://history" in urls, urls)
    sv.launch()
    k = [x["internal"] for x in tabs()]
    t.ok("relaunched: Settings at Privacy and History come back", "search://settings/privacy" in k and "search://history" in k, k)
    t.ok("…History in front, as it was", one(active())["internal"] == "search://history")
    t.ok("…with no web view built for either", all(not x["built"] for x in tabs() if x["internal"]))


def case_split(t):
    """Split View with one of them"""
    sv.setup(splitView=True); sv.launch()
    a = sv.page("a")
    press(COMMA, ",", "cmd")
    s = of("settings")[0]["id"]
    sv.sp("pair", id=s, **{"with": a}, side="right"); time.sleep(0.8)
    x = st()
    t.ok("Settings pairs with a web page", x["splits"] and set(x["splits"][0]["tabs"]) == {a, s}, x["splits"])
    t.ok("…and is still Settings, with no web view", one(s)["internal"].startswith("search://settings") and not one(s)["built"])
    sv.sp("select", id=a); time.sleep(0.4)
    press(COMMA, ",", "cmd")
    x = st()
    t.ok("⌘, from the page beside it: Settings' pane gets the keys, no second tab",
         x["activeID"] == s and len(of("settings")) == 1 and x["splits"], (x["activeID"], s))
    press(W, "w", "cmd")
    x = st()
    t.ok("⌘W closes Settings out of the pair; the page stays", s not in [y["id"] for y in x["tabs"]] and a in [y["id"] for y in x["tabs"]], x["tabs"])


def main():
    t = sv.T()
    for case in [case_open_focus, case_blank_and_private, case_back_forward, case_restore, case_split]:
        print(f"— {case.__doc__}")
        try:
            case(t)
        except Exception as error:
            t.ok(f"{case.__name__} ran to the end", False, error)
        finally:
            sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
