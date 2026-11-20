"""Firefox's and Zen's open tabs and tab groups, brought into a probe world.

Build first (`./build.sh debug`), then, hidden and under the probe lock:
`lockf -t 900 /private/tmp/claude-501/search-probe.lock python3 Tests/gecko_tabs.py`.
A made-up Zen profile and a made-up Firefox profile are written into the
world's own Import folder (never a real browser's), each with the session
store Gecko keeps while it runs, sessionstore-backups/recovery.jsonlz4.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import zen_spaces as zs  # noqa: E402
from zen_spaces import mozlz4, tab, profile, ZEN_TABS  # noqa: E402,F401
import split_view as sv  # noqa: E402

sv.use("gecko-tabs")


def zen():
    zs.zen()
    folder = f"{sv.SUPPORT}/Import/zen/Profiles/probe.Default (release)"
    Path(f"{folder}/sessionstore-backups/recovery.jsonlz4").write_bytes(mozlz4({"windows": [{
        "tabs": ZEN_TABS, "groups": [{"id": "g1", "name": "Reading"}, {"id": "f1", "name": "Research", "pinned": True}]}]}))


def firefox():
    folder = f"{sv.SUPPORT}/Import/Firefox/Profiles/probe.default-release"
    profile(folder)
    Path(f"{folder}/sessionstore-backups/recovery.jsonlz4").write_bytes(mozlz4({"windows": [
        {"tabs": [tab("https://fx-pinned.example/", "Pinned", pinned=True),
                  tab("https://fx-one.example/", "One", group="t1"),
                  tab("https://fx-two.example/", "Two", group="t1"),
                  tab("https://fx-loose.example/", "Loose")],
         "groups": [{"id": "t1", "name": "Trip", "collapsed": True}]},
        {"isPopup": True, "tabs": [tab("https://fx-popup.example/", "Popup")]},
    ]}))



def main():
    t = sv.T()
    try:
        sv.setup()
        zen(); firefox()
        sv.launch()

        tabs = sv.cmd({"do": "import", "from": "Zen", "what": ["tabs"]}).get("tabs") or {}
        t.ok("Zen's open tabs, its pins left behind", tabs.get("added") == 2 and tabs.get("pins") == 0, tabs)
        t.ok("in their group", "Reading" in (tabs.get("groupNames") or []), tabs)

        fx = sv.cmd({"do": "import", "from": "Firefox", "what": ["tabs"]}).get("tabs") or {}
        t.ok("Firefox's open tabs, not the popup's", fx.get("read") == 4 and fx.get("added") == 3, fx)
        t.ok("its pinned tab a pin", fx.get("pins") == 1, fx)
        t.ok("its group made", "Trip" in (fx.get("groupNames") or []), fx)
        fx2 = sv.cmd({"do": "import", "from": "Firefox", "what": ["tabs"]}).get("tabs") or {}
        t.ok("nothing twice", fx2.get("added") == 0 and fx2.get("pins") == 0, fx2)
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
