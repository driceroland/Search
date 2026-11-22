#!/usr/bin/env python3
"""A pin keeps its id, its home and its place in every space when its tab
is swapped between an extension's page and a website, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/pin_swap.py`. It uses the
split suite's harness in a world of its own (see split_view.use()), so it
can run beside that suite. It loads a one-page extension from a folder,
and needs macOS 15.4.
"""
import json
import shutil
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("pin-swap-tests")

t = sv.T()
def pins(): return json.load(open(f"{sv.SUPPORT}/pins.json"))
def pinned():
    st = sv.sp("state"); return [x for x in st["tabs"] if x["id"] in st["pins"]]
folder = Path(tempfile.mkdtemp(prefix="pin-swap-"))
try:
    (folder / "manifest.json").write_text(json.dumps({
        "manifest_version": 3, "name": "Pin Swap", "version": "1.0", "options_page": "options.html",
        "permissions": ["tabs"]}))
    (folder / "options.html").write_text("<!doctype html><title>options</title><p>options")
    (folder / "other.html").write_text("<!doctype html><title>other</title><p>other")
    # Pins every space shows need spaces on (Preferences.showsSharedPins).
    sv.setup(spaces=True, **{"pins.shared": True}); sv.launch()
    sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})

    def extension():
        for _ in range(100):
            loaded = [e for e in sv.cmd({"do": "extensions"})["extensions"] if e["name"] == "Pin Swap" and e["base"]]
            if loaded: return loaded[0]["base"], loaded[0]["id"]
            time.sleep(0.2)
        return "", ""

    base, ext = extension()
    t.ok("the extension loads", base, base)
    space = sv.sp("state")["spaceID"]
    # The bench's `go` takes only a website, so the pin starts on the
    # extension's page and the swap is to the web and back.
    home = base.rstrip("/") + "/options.html"
    m = sv.cmd({"do": "ext-page", "id": ext, "path": "options.html"})["id"]; time.sleep(1)
    sv.cmd({"do": "pin", "id": m})

    def wakes(id, want=None):
        """Select the tab, wait for it to load, and return the address it loaded."""
        want = want or home
        sv.cmd({"do": "select", "id": id}); sv.cmd({"do": "wait", "id": id})
        at = ""
        for _ in range(30):
            at = sv.ev(id, "location.href")
            if at == want: break
            time.sleep(0.1)
        return at

    def own_pins():
        """The pins of this space only, without the pin every space shows."""
        st = sv.sp("state")
        return [x for x in st["tabs"] if x["id"] in st["pins"] and x["id"] not in st["everywhere"]]

    def extension_sends(helper, pin_url, to):
        """As the extension does: chrome.tabs.update on the pinned tab at
        `pin_url`, run from the extension's page in the tab `helper`."""
        sv.ev(helper, """window.__sent = ""; (async () => {
            const pins = await chrome.tabs.query({pinned: true});
            const pin = pins.find((tab) => tab.url === %s);
            if (!pin) { window.__sent = "no such pin: " + JSON.stringify(pins.map((tab) => tab.url)); return; }
            await chrome.tabs.update(pin.id, {url: %s});
            window.__sent = "sent";
        })().catch((error) => { window.__sent = String(error); }); 1""" % (json.dumps(pin_url), json.dumps(to)))
        said = ""
        for _ in range(50):
            said = sv.ev(helper, "window.__sent")
            if said: break
            time.sleep(0.1)
        time.sleep(1)
        return said

    # Case 1: restart. The pin is the selected tab when the app quits.
    # After the relaunch the pin must be asleep at the extension's page, and
    # selecting it must load that page, not about:blank (see Tab.wake).
    sv.cmd({"do": "select", "id": m})
    sv.sp("save"); sv.quit(); time.sleep(0.5); sv.launch()
    t.ok("after a restart the extension is back", extension()[0] == base, base)
    back = pinned()
    t.ok("after a restart the pin is asleep at the extension's page",
         len(back) == 1 and back[0]["url"] == home and back[0]["asleep"], back)
    m = back[0]["id"]
    woke = wakes(m)
    t.ok("after a restart, selecting the pin loads the extension's page", woke == home, woke)
    sv.cmd({"do": "pin", "id": m, "everywhere": True}); sv.sp("save")
    before = pins()["shared"]
    t.ok("pinned at the extension's page, in every space", [p["home"] for p in before] == [home], before)

    def same(when):
        st = sv.sp("state"); tab = [x for x in st["tabs"] if x["id"] in st["pins"]]
        sv.sp("save"); after = pins()
        t.ok(f"{when}: the same pin id and home", [(p["id"], p["home"]) for p in after["shared"]]
             == [(before[0]["id"], home)], after)
        t.ok(f"{when}: still in every space", [x["id"] for x in tab] == st["everywhere"]
             and not after.get(space), (st["everywhere"], after.get(space)))
        return tab

    sv.cmd({"do": "go", "id": m, "url": f"{sv.BASE}/web"}); time.sleep(1.5)
    tab = same("to the web")
    t.ok("to the web: the pin is a new tab at the website", len(tab) == 1 and tab[0]["id"] != m
         and tab[0]["url"] == f"{sv.BASE}/web", tab)
    said = sv.cmd({"do": "pin", "id": tab[0]["id"]})
    t.ok("to the web: the tab's home is the extension's page", said["home"] == home, said)

    # A double-click on the pin goes home, which swaps it back.
    sv.cmd({"do": "pin", "id": tab[0]["id"], "home": True}); time.sleep(1.5)
    tab = same("home")
    t.ok("home: back at the extension's page", len(tab) == 1 and tab[0]["url"] == home, tab)

    # Case 2: ⌘W. Take the pin to a website, then close it. A closed pin
    # goes back to its pinned address (the extension's page) and sleeps.
    # Selecting it must load the extension's page, not about:blank.
    sv.cmd({"do": "go", "id": tab[0]["id"], "url": f"{sv.BASE}/web"}); time.sleep(1.5)
    sv.sp("close", id=pinned()[0]["id"]); time.sleep(0.5)
    down = pinned()
    t.ok("after ⌘W on a website, the pin is asleep at the extension's page",
         len(down) == 1 and down[0]["url"] == home and down[0]["asleep"], down)
    woke = wakes(down[0]["id"])
    t.ok("after ⌘W on a website, selecting the pin loads the extension's page", woke == home, woke)

    # Case 3: the extension moves a sleeping pin to another of its own pages.
    # Put the pin to sleep as in case 2, then, before anyone selects it, the
    # extension sends it to other.html. It must load other.html, not about:blank.
    other = base.rstrip("/") + "/other.html"
    helper = sv.cmd({"do": "ext-page", "id": ext, "path": "other.html"})["id"]; time.sleep(1)
    sv.cmd({"do": "go", "id": down[0]["id"], "url": f"{sv.BASE}/web"}); time.sleep(1.5)
    sv.sp("close", id=pinned()[0]["id"]); time.sleep(0.5)
    said = extension_sends(helper, home, other)
    woke = wakes(pinned()[0]["id"], other)
    t.ok("a sleeping pin the extension sends to another of its pages loads that page",
         said == "sent" and woke == other, (said, woke))

    # Case 4: the opposite direction. A pin whose pinned address is a website
    # is sent to the extension's page, then closed with ⌘W. It goes back to
    # the website and sleeps. Selecting it must load the website.
    site = f"{sv.BASE}/site"
    opened = sv.cmd({"do": "open", "url": site})["id"]; sv.cmd({"do": "wait", "id": opened})
    sv.cmd({"do": "pin", "id": opened})
    said = extension_sends(helper, site, home)
    there = own_pins()
    t.ok("a website's pin the extension sends to its page is at that page",
         said == "sent" and len(there) == 1 and there[0]["url"] == home, (said, there))
    sv.sp("close", id=there[0]["id"]); time.sleep(0.5)
    down = own_pins()
    t.ok("after ⌘W on the extension's page, the website's pin is asleep at the website",
         len(down) == 1 and down[0]["url"] == site and down[0]["asleep"], down)
    woke = wakes(down[0]["id"], site)
    t.ok("after ⌘W on the extension's page, selecting the pin loads the website", woke == site, woke)
    # Leave only the first pin, for whatever follows.
    sv.cmd({"do": "pin", "id": down[0]["id"], "off": True})
    sv.sp("close", id=down[0]["id"]); sv.sp("close", id=helper)
finally:
    t.done(); sv.finish(); shutil.rmtree(folder, ignore_errors=True)
sys.exit(1 if t.failed else 0)
