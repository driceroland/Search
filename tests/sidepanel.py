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
    sys.exit(f"FAIL: {what} (waited {seconds}s)")


def expect(what, ok):
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        sys.exit(1)


class Run:
    def __init__(self, app):
        self.binary = os.path.join(app, "Contents", "MacOS", "Search")
        self.process = None

    def start(self):
        # The bench listens only when Settings' switch is on; in a test world
        # the switch alone is enough (no keychain mark is asked for).
        subprocess.run(["defaults", "write", "com.officecommun.search.test", "bench", "-bool", "true"], check=True)
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
    run.start()
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
        ask({"do": "resize", "width": 640, "height": 500})
        time.sleep(0.6)
        expect("a narrow window leaves the page 320 beside the panel", (panel() or {}).get("width") == 320)
        ask({"do": "ui", "sidebar": True})
        time.sleep(0.6)
        expect("with the column too, the panel stops at its minimum", (panel() or {}).get("width") == 280)
        ask({"do": "ui", "sidebar": False})
        ask({"do": "resize", "width": 1180, "height": 780})
        time.sleep(0.6)

        # Task 4: closing from the page, links out, self-navigation, no path, reload.
        fire(fixture, "window.close()")
        time.sleep(0.4)
        expect("window.close() from the panel closes it", panel() == "")
        press_until_up(fixture)
        fire(fixture, "chrome.sidePanel.setOptions({enabled: false})")
        time.sleep(0.4)
        expect("setOptions({enabled: false}) closes it", panel() == "")
        press_until_up(fixture)
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
        expect("sidePanel.open() with no path rejects", said.startswith("error:") and "path" in said)

        ask({"do": "ext-reload", "id": fixture})
        until("the panel to close on reload", lambda: panel() == "")
        until("the fixture to load again", lambda: loaded("Side panel fixture"))
        press_until_up(fixture)
        expect("the panel comes back after a reload", (panel() or {}).get("id") == fixture)

        # Task 5: the width is remembered across a relaunch.
        width = (panel() or {}).get("width")
        run.stop()
        run.start()
        until("the fixture after relaunch", lambda: loaded("Side panel fixture"))
        page = ask({"do": "open", "url": "https://example.com/"})["id"]
        ask({"do": "wait", "id": page, "seconds": 20})
        press_until_up(fixture)
        expect("the width survives a relaunch", (panel() or {}).get("width") == width)

        ask({"do": "ext-remove", "id": fixture})
        ask({"do": "ext-remove", "id": nopanel})
        print("all checks passed")
        return 0
    finally:
        run.stop()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
