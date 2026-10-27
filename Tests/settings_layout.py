#!/usr/bin/env python3
"""Settings in sections and groups, with Find a setting (SettingsIndex.swift),
checked in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/settings_layout.py`. It uses
split_view.py's harness in a world of its own (bld-set2-<checkout>): started
hidden, driven through ./bench's socket, everything removed afterwards.
Nothing here makes, shows or brings forward a window.

- every setting Settings had before the rework is still reachable from the
  find field, by words someone would type, or says it is always on now;
- the merged controls write the keys the two switches did;
- new defaults reach only keys nobody touched;
- an explicit off on a switch that left Settings stays off.
"""
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bld-set2")

# Every key a switch or choice of Settings wrote before the rework, with
# words that should find it.
BEFORE = {
    "quit.confirm": "quitting", "downloads": "save to", "downloads.ask": "ask where",
    "downloads.button": "downloads button", "look": "dark mode", "pages.dusk": "darken",
    "sidebar": "sidebar", "sidebar.position": "right", "sidebar.hides": "hide the column",
    "layout.cards": "card", "toolbar.left": "back forward", "sidebar.roomy": "roomier",
    "glyph": "favicon", "tabs.reading": "how far", "tabs.give": "pressed", "bookmarks.bar": "bookmarks bar",
    "motion.light": "low power", "tabs.newPlace": "new tab position", "tabs.newAfterLast": "last tab",
    "tabs.lazy": "background tabs", "tabs.popupWindows": "pop-ups", "tabs.sleep": "sleep",
    "tabs.sleep.pace": "sleep", "tabs.close.after": "close tabs", "tabs.shortcuts": "numbers",
    "tabs.address": "address", "search.engine": "search with", "search.custom": "engine",
    "search.suggest": "suggestions", "search.keywords": "site shortcuts", "links.little": "small window",
    "reader.twins": "markdown", "reader.follows": "reading mode", "float.style": "picture in picture",
    "float.leave": "float", "float.away": "switch apps", "media.click": "autoplay",
    "fullscreen.escapeTwice": "esc", "pageZoom": "zoom", "pages.120.mode": "120", "spaces": "spaces",
    "pins.home": "pins", "pins.peek": "pins", "pins.list": "pinned rows", "newtab.floating": "floating",
    "commandbar": "commands", "start.fresh": "fresh window", "passwords.save": "save passwords",
    "passwords.fill": "fill", "passkeys": "passkeys", "passwords.apple": "apple passwords",
    "shield": "ads", "sites.keep": "tracking", "notifications.ask": "notifications",
    "links.peek": "peek", "links.peekClick": "peek", "autoscroll": "middle button",
    "swipe.history": "swipe", "auto.install": "updates", "bench": "script",
    "autocorrect": "spelling",
    # Always on now: the find field says so.
    "splitView": "split", "tabs.groups": "groups", "panel.sites": "side panel",
    "translate.pages": "translate", "tabs.keepAwake": "awake", "search.sites": "site from the address",
    "pins.shared": "every space", "pins.numberBack": "number again", "switcher.keys": "switcher",
    "links.show": "where links go", "float.flicks": "flick",
}
ALWAYS = {"splitView", "tabs.groups", "panel.sites", "translate.pages", "tabs.keepAwake", "search.sites",
          "pins.shared", "pins.numberBack", "switcher.keys", "links.show", "float.flicks"}


def settings(**f): return sv.cmd({"do": "settings", **f})
def read(key):
    out = subprocess.run(["defaults", "read", sv.SUITE, key], capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 else None


def case_reachable(t):
    """every setting from before is found by its words"""
    sv.setup(); sv.launch()
    every = settings()
    items = every["items"]
    keys = {k for i in items for k in i["keys"]}
    # The updates switch's key, as Updater names it.
    install = next((i["keys"][0] for i in items if i["id"] == "updates.auto"), None)
    for key, words in BEFORE.items():
        key = install if key == "auto.install" else key
        found = settings(find=words)["found"]
        hit = [i for i in found if key in i["keys"]]
        t.ok(f"“{words}” finds {key}", bool(hit), [i["id"] for i in found])
        if hit and key in ALWAYS:
            t.ok(f"…and says {key} is always there", hit[0]["note"] and hit[0]["findOnly"], hit[0])
    t.ok("no key is left out of the rows", set(BEFORE) - {"auto.install"} <= keys, set(BEFORE) - keys)
    # Every result names its section and group.
    found = settings(find="video")["found"]
    t.ok("results carry section and group", found and all(i["page"] and i["groupTitle"] for i in found), found)
    t.ok("…in Browsing › Video", any(i["page"] == "browsing" and i["groupTitle"] == "Video" for i in found))
    shown = [i for i in items if not i["findOnly"]]
    t.ok("about fifty rows in the sections", 45 <= len(shown) <= 70, len(shown))
    t.ok("ten sections", len(every["pages"]) == 10, every["pages"])
    # Old addresses land in the new sections.
    sv.cmd({"do": "ui", "show": "search://settings/shortcuts"}); time.sleep(0.6)
    t.ok("search://settings/shortcuts opens Keyboard & Mouse", settings()["settingsPage"] == "keyboard",
         settings()["settingsPage"])
    sv.cmd({"do": "ui", "show": "search://settings/downloads"}); time.sleep(0.6)
    t.ok("search://settings/downloads opens General", settings()["settingsPage"] == "general")


def case_defaults(t):
    """new defaults reach only untouched keys; nothing written just by reading"""
    sv.setup(); sv.launch()
    v = settings()["values"]
    t.ok("pins keep their site, untouched", v["pins.keep"] is True and v["pins.home"] and v["pins.peek"], v)
    t.ok("120 Hz on power, untouched", v["pages.120"] == "onPower", v["pages.120"])
    t.ok("hold a swipe on, untouched", v["swipe.history"] is True)
    t.ok("address on the tab on, untouched", v["tabs.address"] is True)
    t.ok("links shown and flicks on, as before", v["links.show"] is True and v["float.flicks"] is True)
    t.ok("sleep Normal, float on switching tabs, peek with Shift", (v["tabs.sleep"], v["float.own"], v["links.peek"]) == ("normal", "tabs", "shift"), v)
    t.ok("every always-on feature is on", all(v["always"].values()), v["always"])
    for key in ["pins.home", "pins.peek", "pages.120.mode", "swipe.history", "tabs.address"]:
        t.ok(f"{key} not written by reading it", read(key) is None, read(key))


def case_explicit(t):
    """explicit choices stand: offs on removed switches, old 120 Hz, pins"""
    sv.setup(**{"links.show": False, "float.flicks": False, "pages.120": False, "swipe.history": False,
                "tabs.address": False, "pins.home": False, "splitView": False, "tabs.groups": False,
                "panel.sites": False})
    sv.launch()
    v = settings()["values"]
    t.ok("show where links go stays off", v["links.show"] is False)
    t.ok("flick stays off", v["float.flicks"] is False)
    t.ok("an old 120 Hz off is Never", v["pages.120"] == "never", v["pages.120"])
    t.ok("hold a swipe stays off", v["swipe.history"] is False)
    t.ok("address on the tab stays off", v["tabs.address"] is False)
    t.ok("one pin key off, the other unset: off", v["pins.keep"] is False, v)
    t.ok("an old off on a command-only switch is on now", all(v["always"].values()), v["always"])
    sv.quit(); time.sleep(0.5)
    sv.setup(**{"pins.peek": True, "pins.home": False}); sv.launch()
    v = settings()["values"]
    t.ok("either pin key on: on, both kept in step", v["pins.keep"] and v["pins.home"] and v["pins.peek"], v)


def case_merged(t):
    """merged controls write the keys the two switches did"""
    sv.setup(); sv.launch()
    def put(id, value): return settings(set=id, value=value)["values"]
    v = put("tabs.layout", "right")
    t.ok("Tabs: Right writes sidebar and its position", (read("sidebar"), read("sidebar.position")) == ("1", "right"), (read("sidebar"), read("sidebar.position")))
    v = put("tabs.layout", "icons")
    t.ok("Tabs: Icons only writes sidebar and sidebar.icons, keeps the side",
         (read("sidebar"), read("sidebar.icons"), read("sidebar.position")) == ("1", "1", "right") and v["tabs.layout"] == "icons",
         (read("sidebar"), read("sidebar.icons"), read("sidebar.position"), v["tabs.layout"]))
    v = put("tabs.layout", "right")
    t.ok("Tabs: Right after Icons only turns the icons off", read("sidebar.icons") == "0" and v["tabs.layout"] == "right", read("sidebar.icons"))
    v = put("tabs.layout", "top")
    t.ok("Tabs: Top writes sidebar off, keeps the position", read("sidebar") == "0" and v["tabs.layout"] == "top")
    put("tabs.sleep", "never")
    t.ok("Sleep: Never writes tabs.sleep off", read("tabs.sleep") == "0")
    put("tabs.sleep", "later")
    t.ok("Sleep: Later writes on and the pace", (read("tabs.sleep"), read("tabs.sleep.pace")) == ("1", "later"))
    put("float.own", "tabsOrApps")
    t.ok("Float: Tabs or apps writes both on", (read("float.leave"), read("float.away")) == ("1", "1"))
    put("float.own", "never")
    t.ok("Float: Never writes both off", (read("float.leave"), read("float.away")) == ("0", "0"))
    put("pins.keep", False)
    t.ok("Pins keep their site off writes both keys", (read("pins.home"), read("pins.peek")) == ("0", "0"))
    put("links.peek", "optionShift")
    t.ok("Peek: Option-Shift writes on and the click", (read("links.peek"), read("links.peekClick")) == ("1", "optionShift"))
    put("links.peek", "off")
    t.ok("Peek: Off writes links.peek off, keeps the click", (read("links.peek"), read("links.peekClick")) == ("0", "optionShift"))
    v = put("arc.setup", True)
    t.ok("Set Up Like Arc: left, spaces, rows, pins, floating new tab",
         v["arc"] and v["tabs.layout"] == "left" and read("spaces") == "1" and read("pins.list") == "1"
         and read("newtab.floating") == "1" and v["pins.keep"], v)
    # And it survives a relaunch, read back from the keys alone.
    sv.quit(); time.sleep(0.5); sv.launch()
    v = settings()["values"]
    t.ok("after a relaunch the merged values read back", v["arc"] and v["tabs.sleep"] == "later" and v["float.own"] == "never" and v["links.peek"] == "off", v)


def main():
    t = sv.T()
    cases = [case_reachable, case_defaults, case_explicit, case_merged]
    try:
        for case in cases:
            print(case.__doc__)
            try:
                case(t)
            except Exception as error:  # noqa: BLE001
                t.ok(f"{case.__name__} ran", False, repr(error))
            sv.quit(); time.sleep(0.5)
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
