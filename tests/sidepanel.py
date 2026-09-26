#!/usr/bin/env python3
"""The extension side panel, checked against a test run of the built app.

    ./build.sh debug && tests/sidepanel.py [--app build/Search.app]

Launches build/Search.app as a SEARCH_PROBE=1 run (its own world, "Search
(test)"), drives it over the bench socket, and quits it — only ever the
process it started. Exits non-zero on the first check that fails.
"""

import json
import os
import signal
import socket
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURE = os.path.join(ROOT, "tests", "sidepanel", "fixture")
NOPANEL = os.path.join(ROOT, "tests", "sidepanel", "nopanel")
REMEMBER = os.path.join(ROOT, "tests", "sidepanel", "remember")
WORLD = os.path.expanduser("~/Library/Application Support/Search (test)")
SOCKET = os.path.join(WORLD, "bench.sock")


def ask(request):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.connect(SOCKET)
        s.sendall((json.dumps(request) + "\n").encode())
        chunks = []
        while True:
            chunk = s.recv(1 << 16)
            if not chunk:
                break
            chunks.append(chunk)
    line = b"".join(chunks).split(b"\n", 1)[0]
    return json.loads(line or b"{}")


# SIDEPANEL_KEEP_GOING=1 runs every check and fails at the end, for watching a
# new check fail before its fix; otherwise the first failure stops the run.
KEEP_GOING = os.environ.get("SIDEPANEL_KEEP_GOING") == "1"
failures = []


def until(what, check, seconds=20, every=0.25):
    """Polls check() until it returns something truthy; that value."""
    end = time.time() + seconds
    while time.time() < end:
        try:
            got = check()
        except (FileNotFoundError, ConnectionRefusedError, json.JSONDecodeError):
            got = None
        if got:
            return got
        time.sleep(every)
    if KEEP_GOING:
        print(f"FAIL {what} (waited {seconds}s)")
        failures.append(what)
        return None
    sys.exit(f"FAIL: {what} (waited {seconds}s)")


def expect(what, ok):
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        if KEEP_GOING:
            failures.append(what)
            return
        sys.exit(1)


class Run:
    def __init__(self, app):
        self.binary = os.path.join(app, "Contents", "MacOS", "Search")
        self.process = None

    def start(self, fresh=False):
        # The bench listens only when Settings' switch is on; in a test world
        # the switch alone is enough (no keychain mark is asked for).
        subprocess.run(["defaults", "write", "com.officecommun.search.test", "bench", "-bool", "true"], check=True)
        # The first start begins from the default layout — tabs across the
        # top, the panel and the column at their default widths — whatever an
        # earlier run that stopped midway, or a hand on an edge, left behind.
        if fresh:
            for key in ("panel.width", "sidebar", "sidebar.width"):
                subprocess.run(["defaults", "delete", "com.officecommun.search.test", key], capture_output=True)
        env = dict(os.environ, SEARCH_PROBE="1")
        self.process = subprocess.Popen([self.binary], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        until("the bench socket", lambda: os.path.exists(SOCKET) and ask({"do": "probe"}), seconds=40)

    def stop(self):
        if self.process and self.process.poll() is None:
            self.process.send_signal(signal.SIGTERM)
            try:
                self.process.wait(10)
            except subprocess.TimeoutExpired:
                self.process.kill()
        self.process = None


def loaded(name):
    """The installed extension called name, once it is loaded; else None."""
    for item in ask({"do": "extensions"}).get("extensions", []):
        if item.get("name") == name and item.get("loaded"):
            return item
    return None


def install(folder, name):
    # A run that failed left its copy behind; a second copy would be found first.
    for item in ask({"do": "extensions"}).get("extensions", []):
        if item.get("name") == name:
            ask({"do": "ext-remove", "id": item["id"]})
    until(f"no earlier {name}", lambda: not any(i.get("name") == name for i in ask({"do": "extensions"}).get("extensions", [])))
    ask({"do": "ext-answer", "answer": "yes"})
    ask({"do": "ext-folder", "path": folder, "yes": True})
    return until(f"{name} loaded", lambda: loaded(name), seconds=30)


def panel():
    return ask({"do": "probe"}).get("panel")


def press_until_up(ext):
    """Presses the button until the panel is up: the worker sets the
    button's behaviour when it starts, and a press before that does nothing."""
    for _ in range(8):
        ask({"do": "ext-press", "id": ext})
        time.sleep(0.6)
        p = panel()
        if p and p.get("id") == ext:
            return p
    sys.exit("FAIL: the panel never came up from the button")


def in_panel(ext, js):
    got = ask({"do": "ext-panel", "id": ext, "js": js})
    if "error" in got:
        sys.exit(f"FAIL: ext-panel: {got['error']}")
    return got.get("value")


def fire(ext, js):
    """Runs js in the panel for its effect; a promise or a window it leaves
    behind is not something WebKit can hand back, so nothing is asked for."""
    in_panel(ext, js + "; undefined")


def settled(ext, js, seconds=10):
    """Runs js, which must leave its answer in window.__r, and reads it. The
    statement's own value is a promise WebKit can't hand back, so it ends
    on one it can."""
    in_panel(ext, "window.__r = undefined; " + js + "; undefined")
    return until("a value in window.__r", lambda: in_panel(ext, "window.__r"), seconds)


def main(argv):
    app = os.path.join(ROOT, "build", "Search.app")
    if "--app" in argv:
        app = os.path.abspath(argv[argv.index("--app") + 1])
    if not os.path.exists(app):
        sys.exit(f"no app at {app} — ./build.sh debug first")
    run = Run(app)
    run.start(fresh=True)
    try:
        fixture = install(FIXTURE, "Side panel fixture")["id"]
        page = ask({"do": "open", "url": "https://example.com/"})["id"]
        ask({"do": "wait", "id": page, "seconds": 20})
        ask({"do": "select", "id": page})

        # Task 2: the panel comes up from the button, and goes on a second press.
        up = press_until_up(fixture)
        expect("probe reports the panel", up.get("id") == fixture and up.get("name") == "Side panel fixture")
        ask({"do": "ext-press", "id": fixture})
        time.sleep(0.4)
        expect("a second press puts it away", panel() == "")

        # Task 3: it is on screen, on the right, the page's height.
        press_until_up(fixture)
        probe = ask({"do": "probe"})
        frame = probe.get("panelFrame")
        window = next((w for w in probe.get("windows", []) if w.get("kind") == "SearchWindow" or w.get("title") == "Search"), None)
        expect("the panel has a frame", isinstance(frame, list) and len(frame) == 4 and frame[2] == probe["panel"]["width"])
        if window:
            x, y, w, h = frame
            expect("the panel stands at the window's right edge", abs((x + w) - window["frame"][2]) <= 1)
            expect("the panel is at least as tall as half the window", h >= window["frame"][3] / 2)
        expect("the panel's page runs", settled(fixture, "window.__r = document.getElementById('h').textContent") == "Fixture panel")

        # Task 3: what the extension sees from inside the panel.
        active = settled(fixture, "chrome.tabs.query({active: true}).then(t => window.__r = JSON.stringify(t.map(x => x.url)))")
        expect("tabs.query({active:true}) is the page, not the panel", "example.com" in active and "chrome-extension" not in active)
        current = settled(fixture, "chrome.tabs.getCurrent().then(t => window.__r = t === undefined ? 'undefined' : JSON.stringify(t))")
        expect("tabs.getCurrent() is undefined", current == "undefined")
        win = settled(fixture, "chrome.windows.getCurrent().then(w => window.__r = String(w && w.id))")
        expect("windows.getCurrent() has an id", win not in ("undefined", "null", "NaN", None))
        echo = settled(fixture, "(() => { const p = chrome.runtime.connect(); p.onMessage.addListener(m => window.__r = JSON.stringify(m)); p.postMessage({hi: 1}) })()")
        expect("a runtime.connect port reaches the worker and back", echo == '{"echo":{"hi":1}}')
        layout = settled(fixture, "chrome.sidePanel.getLayout().then(l => window.__r = l && l.side)")
        expect("getLayout() is the right-hand column", layout == "right")
        events = settled(fixture, "chrome.runtime.sendMessage('panel-events').then(e => { if ((e || []).some(x => String(x).indexOf('opened:') === 0)) window.__r = JSON.stringify(e) })", seconds=8)
        expect("the worker hears sidePanel.onOpened", bool(events) and "opened:panel.html" in events)
        def href():
            got = ask({"do": "ext-panel", "id": fixture, "js": "location.href"})
            return got.get("value") if "error" not in got else None
        fire(fixture, "chrome.sidePanel.setOptions({path: 'panel.html?x=1#z'})")
        found = until("the open panel to follow its new path", lambda: found if isinstance(found := href(), str) and "x=1" in found else None, seconds=8)
        expect("a path keeps its query and its hash", bool(found) and "x=1" in (found or "") and "#z" in (found or ""))
        fire(fixture, "chrome.sidePanel.setOptions({path: 'panel.html'})")
        until("the panel page restored", lambda: isinstance(now := href(), str) and now.split("?")[0].endswith("/panel.html") and "x=1" not in now, seconds=8)

        # Task 3: the panel survives a tab switch.
        other = ask({"do": "open", "url": "https://example.org/"})["id"]
        ask({"do": "wait", "id": other, "seconds": 20})
        ask({"do": "select", "id": other})
        time.sleep(0.4)
        expect("the panel stays across a tab switch", (panel() or {}).get("id") == fixture)
        ask({"do": "select", "id": page})

        # Task 3: a narrow window clamps the panel so the page keeps 320 —
        # and with the column of tabs taking its share too, the panel stops
        # at its own minimum rather than squeezing the page further.
        # The window is taken there in steps, like a drag, so the width is
        # waited for rather than read after a fixed pause.
        ask({"do": "resize", "width": 640, "height": 500})
        until("the window at 640", lambda: (panel() or {}).get("width") == 320, seconds=8)
        expect("a narrow window leaves the page 320 beside the panel", (panel() or {}).get("width") == 320)
        # With the column of tabs out as well (232 by default), even the
        # panel's minimum would leave the page under 160: the panel gives
        # way, and stays clear of the column and inside the window.
        ask({"do": "ui", "sidebar": True})
        until("the column out", lambda: (panel() or {}).get("width", 999) < 280, seconds=8)
        frame = ask({"do": "probe"}).get("panelFrame") or [0, 0, 0, 0]
        expect("with the column too, the panel gives way and the page keeps 160",
               frame[2] < 280 and frame[0] - 232 >= 160 and frame[0] + frame[2] <= 641)
        ask({"do": "ui", "sidebar": False})
        ask({"do": "resize", "width": 1180, "height": 780})
        until("the window back at 1180", lambda: (panel() or {}).get("width") == 360, seconds=8)

        # Task 4: closing from the page, links out, self-navigation, no path, reload.
        fire(fixture, "window.close()")
        time.sleep(0.4)
        expect("window.close() from the panel closes it", panel() == "")
        press_until_up(fixture)
        # Chrome's site-specific pattern disables the panel per tab for every
        # other tab; that must not close the one the user is working in.
        fire(fixture, "chrome.sidePanel.setOptions({tabId: 123456789, enabled: false})")
        time.sleep(0.6)
        expect("setOptions({tabId, enabled: false}) leaves the panel alone", (panel() or {}).get("id") == fixture)
        # The tab in front, disabled: the panel is hidden, and comes back when enabled.
        fire(fixture, "chrome.tabs.query({active: true}).then(t => chrome.sidePanel.setOptions({tabId: t[0].id, enabled: false}))")
        until("the panel hidden on its own tab", lambda: panel() == "", seconds=6)
        expect("the tab in front can hide its panel", panel() == "")
        restore = ask({"do": "ext-page", "id": fixture, "path": "panel.html"})["id"]
        ask({"do": "wait", "id": restore, "seconds": 15})
        ask({"do": "eval", "id": restore, "js": "chrome.tabs.query({active:true}).then(t => chrome.sidePanel.setOptions({tabId: t[0].id, enabled: true})); undefined"})
        until("the panel back on its tab", lambda: (panel() or {}).get("id") == fixture, seconds=6)
        fire(fixture, "chrome.sidePanel.setOptions({enabled: false})")
        time.sleep(0.4)
        expect("setOptions({enabled: false}) closes it", panel() == "")
        # The tab in front was given its own enabled:true above, which outranks
        # the window setting. Turn that off too, or the button may open it.
        ask({"do": "eval", "id": restore, "js": "chrome.tabs.query({active:true}).then(t => chrome.sidePanel.setOptions({tabId: t[0].id, enabled: false})); undefined"})
        time.sleep(0.4)
        ask({"do": "ext-press", "id": fixture})
        time.sleep(0.5)
        expect("a disabled panel stays down", panel() == "")
        ask({"do": "eval", "id": restore, "js": "chrome.tabs.query({active:true}).then(t => chrome.sidePanel.setOptions({tabId: t[0].id, enabled: true})); chrome.sidePanel.setOptions({enabled: true}); undefined"})
        time.sleep(0.3)
        press_until_up(fixture)
        # A download link in the panel is a download, not the panel's next page:
        # the file lands in this world's own downloads folder and the panel stays.
        # (A blob, as panels export: a download of one of the extension's own
        # files is refused by WebKit's extension scheme, in a tab as well.)
        downloads = os.path.join(WORLD, "Downloads")
        for name in os.listdir(downloads) if os.path.isdir(downloads) else []:
            if name.startswith("export"):
                os.remove(os.path.join(downloads, name))
        fire(fixture, "exportBlob()")
        until("the export to land in Downloads", lambda: os.path.isdir(downloads) and any(n.startswith("export") for n in os.listdir(downloads)), seconds=10)
        expect("a download link keeps the panel's page", (settled(fixture, "window.__r = location.href") or "").endswith("/panel.html"))
        before = len(ask({"do": "tabs"}).get("tabs", []))
        fire(fixture, "window.open('https://example.net/')")
        until("a tab for the link", lambda: len(ask({"do": "tabs"}).get("tabs", [])) > before)
        expect("a link out of the panel is a tab, and the panel stays", (panel() or {}).get("id") == fixture)
        before = len(ask({"do": "tabs"}).get("tabs", []))
        fire(fixture, "location.href = 'https://example.edu/'")
        until("a tab for the navigation", lambda: len(ask({"do": "tabs"}).get("tabs", [])) > before)
        time.sleep(0.6)
        expect("the panel keeps its own page after navigating away", settled(fixture, "window.__r = location.href").startswith("chrome-extension://"))

        nopanel = install(NOPANEL, "No panel fixture")["id"]
        probe_tab = ask({"do": "ext-page", "id": nopanel, "path": "page.html"})["id"]
        ask({"do": "wait", "id": probe_tab, "seconds": 20})
        ask({"do": "eval", "id": probe_tab, "js": "window.__r = undefined; chrome.sidePanel.open({}).then(() => window.__r = 'opened', e => window.__r = 'error: ' + e.message); undefined"})
        said = until("sidePanel.open to settle", lambda: ask({"do": "eval", "id": probe_tab, "js": "window.__r"}).get("value"))
        expect("sidePanel.open() needs a tab or a window", isinstance(said, str) and said.startswith("error:") and ("tabId" in said or "windowId" in said))
        ask({"do": "eval", "id": probe_tab, "js": "window.__r = undefined; chrome.windows.getCurrent().then(w => chrome.sidePanel.open({windowId: w.id})).then(() => window.__r = 'opened', e => window.__r = 'error: ' + e.message); undefined"})
        said = until("sidePanel.open with a window to settle", lambda: ask({"do": "eval", "id": probe_tab, "js": "window.__r"}).get("value"))
        expect("sidePanel.open() with no path rejects", isinstance(said, str) and said.startswith("error:") and "path" in said)

        ask({"do": "ext-reload", "id": fixture})
        until("the panel to close on reload", lambda: panel() == "")
        until("the fixture to load again", lambda: loaded("Side panel fixture"))
        press_until_up(fixture)
        expect("the panel comes back after a reload", (panel() or {}).get("id") == fixture)

        # Set once at install, as Chrome's own samples do, and still true
        # after a relaunch: the browser remembers it, the worker does not say it again.
        remember = install(REMEMBER, "Remember panel")["id"]
        press_until_up(remember)
        expect("a panel set at install opens", (panel() or {}).get("id") == remember)
        ask({"do": "ext-press", "id": remember})
        time.sleep(0.4)

        # Task 5: the width is remembered across a relaunch. A width nobody
        # dragged to is written to the store first, so a Prefs that never
        # saved or never read would be caught; and the column of tabs is
        # made as wide as it goes, for the narrow-window check below.
        run.stop()
        subprocess.run(["defaults", "write", "com.officecommun.search.test", "panel.width", "-float", "420"], check=True)
        subprocess.run(["defaults", "write", "com.officecommun.search.test", "sidebar.width", "-float", "440"], check=True)
        run.start()
        until("the fixture after relaunch", lambda: loaded("Side panel fixture"))
        until("the remembered panel after relaunch", lambda: loaded("Remember panel"))
        press_until_up(remember)
        expect("the button still opens the panel after a relaunch", (panel() or {}).get("id") == remember)
        ask({"do": "ext-press", "id": remember})
        time.sleep(0.4)
        page = ask({"do": "open", "url": "https://example.com/"})["id"]
        ask({"do": "wait", "id": page, "seconds": 20})
        ask({"do": "resize", "width": 1180, "height": 780})
        press_until_up(fixture)
        until("the stored width", lambda: (panel() or {}).get("width") == 420, seconds=8)
        expect("the width survives a relaunch", (panel() or {}).get("width") == 420)

        # A window too narrow for the widest column plus the panel: the panel
        # gives way rather than overflowing the window or covering the column.
        ask({"do": "ui", "sidebar": True})
        ask({"do": "resize", "width": 640, "height": 500})
        until("the window at 640 with the column out", lambda: (ask({"do": "probe"}).get("panelFrame") or [0, 0, 0, 0])[0] + (ask({"do": "probe"}).get("panelFrame") or [0, 0, 0, 0])[2] <= 641, seconds=8)
        frame = ask({"do": "probe"}).get("panelFrame") or [0, 0, 0, 0]
        expect("the panel stays inside the window beside the widest column", frame[0] >= 440 and frame[0] + frame[2] <= 641 and frame[2] > 0)
        ask({"do": "ui", "sidebar": False})
        ask({"do": "resize", "width": 1180, "height": 780})
        subprocess.run(["defaults", "delete", "com.officecommun.search.test", "sidebar.width"], capture_output=True)

        ask({"do": "ext-remove", "id": fixture})
        ask({"do": "ext-remove", "id": nopanel})
        ask({"do": "ext-remove", "id": remember})
        if failures:
            print(f"{len(failures)} check(s) failed: " + "; ".join(failures))
            return 1
        print("all checks passed")
        return 0
    finally:
        run.stop()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
