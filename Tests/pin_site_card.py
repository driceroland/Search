#!/usr/bin/env python3
"""A pin's Site Information… (idea 1081), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/pin_site_card.py`. A pin's
right-click menu offers Site Information… as a tab's does, wherever the
pin is drawn: a square in the column, a row (Settings › pins as a list), a
row in a pin folder, a square in the row across the top. The card comes
up for the pin, and its Block Ads and Trackers switch, turned off, reaches
the pin's page: it reloads without the blocker, so a slot the blocker
hides (`.ad-slot`) shows; on again, it is hidden again. The card is a
child window of the hidden probe's window, never on a screen.

And every pin state (idea 1118): a pin you aren't on, the one you are
on, one put down with ⌘W, and, after a relaunch, pins brought back
asleep and awake — as a square, a row, a row in a folder, a tile of the
column of icons, a square in the top row. Before, the card came for none
of the squares brought back at launch nor the one you were on, and never
in the column of icons.
"""
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("pin-site-card")


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        body = (f"<!doctype html><title>{self.path.strip('/')}</title>"
                "<div class='ad-slot' id='ad' style='height:40px'>slot</div>"
                "<script>window.loads = (performance.getEntriesByType('navigation')[0] || {}).type</script>").encode()
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), Page); threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"


def open_page(name):
    r = sv.sp("open", url=f"{BASE}/{name}")["resultID"]; time.sleep(1.0); return r


def ad(id):
    return sv.ev(id, "getComputedStyle(document.getElementById('ad')).display")


def wait_ad(id, want, within=6):
    until = time.time() + within
    seen = None
    while time.time() < until:
        try: seen = ad(id)
        except Exception: seen = None
        if seen == want: return seen
        time.sleep(0.25)
    return seen


def run(t, name, prefs, folder=False, square=False, listed=False):
    sv.setup(**prefs); sv.launch()
    pin = open_page("pinned"); sv.page("other")
    if folder:
        sv.cmd({"do": "pinfolder", "action": "on"})
        sv.cmd({"do": "pinfolder", "action": "pin", "id": pin})
        sv.cmd({"do": "pinfolder", "action": "new", "name": "Work", "id": pin}); time.sleep(0.6)
    else:
        sv.cmd({"do": "pin", "id": pin, "listed": listed}); time.sleep(0.6)
    t.ok(f"{name}: the blocker hides the slot on the pin's page", wait_ad(pin, "none") == "none", ad(pin))
    # From another tab, as a right-click on a pin you aren't on.
    sv.cmd({"do": "ui", "siteinfo": True, "siteinfoid": pin[:8]}); time.sleep(1.0)
    p = sv.cmd({"do": "probe"})
    t.ok(f"{name}: Site Information… brings the pin's card", p["siteCard"] and p["siteCardTab"] == pin[:8].lower(), (p["siteCard"], p["siteCardTab"]))
    # A square has no address to open: the card hangs from the square, and
    # nothing is being edited. A row (and a top-row pin) opens its address
    # with the card under it, as a tab's does.
    t.ok(f"{name}: {'under the square, no address opened' if square else 'under the address opened in the pin'}",
         (p["tabEditing"] == "") == square, p["tabEditing"])
    sv.cmd({"do": "ui", "cardblocker": False}); time.sleep(0.4)
    t.ok(f"{name}: the switch turned off reaches the pin's page: reloaded, the slot shows", wait_ad(pin, "block") == "block", ad(pin))
    t.ok(f"{name}: …reloaded, not taken elsewhere", sv.ev(pin, "location.pathname + ' ' + window.loads") == "/pinned reload", sv.ev(pin, "location.pathname + ' ' + window.loads"))
    sv.cmd({"do": "ui", "cardblocker": True}); time.sleep(0.4)
    t.ok(f"{name}: on again, the slot is hidden again", wait_ad(pin, "none") == "none", ad(pin))
    sv.quit()


def card_for(t, label, pid, square):
    """Site Information… on `pid`: its card up, hung from the square (no
    address opened) or from the address opened in it, inside the window."""
    sv.cmd({"do": "ui", "finishedit": True}); time.sleep(0.3)
    sv.cmd({"do": "ui", "siteinfo": True, "siteinfoid": pid[:8]}); time.sleep(1.0)
    p = sv.cmd({"do": "probe"})
    frames = p.get("siteCardFrames", {})
    card, win = frames.get("card"), frames.get("window")
    # Its top edge under the window's top and its left edge within 20
    # points of the window's: hung from the column (or the top row), not
    # somewhere else on the screen.
    placed = bool(card and win and win[0] - 20 <= card[0] <= win[0] + win[2] and card[1] + card[3] <= win[1] + win[3])
    t.ok(f"{label}: Site Information… brings its card", p["siteCard"] and p["siteCardTab"] == pid[:8].lower() and placed,
         (p["siteCard"], p["siteCardTab"], pid[:8], card, win))
    t.ok(f"{label}: {'under the square, no address opened' if square else 'under the address opened in it'}",
         (p["tabEditing"] == "") == square, p["tabEditing"])
    # Put away: the square's own Site Information… again, or the edit ended.
    if p["siteCard"] and p["tabEditing"] == "":
        sv.cmd({"do": "ui", "siteinfo": True, "siteinfoid": pid[:8]}); time.sleep(0.4)
    sv.cmd({"do": "ui", "finishedit": True}); time.sleep(0.3)
    t.ok(f"{label}: put away", not sv.cmd({"do": "probe"})["siteCard"])


def states(t, name, prefs, square=False, listed=False, folder=False):
    """Idea 1118: fresh, on, put down, and brought back asleep and awake."""
    sv.setup(**prefs); sv.launch()
    a = open_page("a"); b = open_page("b"); sv.page("other")
    for pid in (a, b):
        if folder:
            sv.cmd({"do": "pinfolder", "action": "on"})
            sv.cmd({"do": "pinfolder", "action": "pin", "id": pid})
        else:
            sv.cmd({"do": "pin", "id": pid, "listed": listed})
    if folder:
        sv.cmd({"do": "pinfolder", "action": "new", "name": "Work", "id": a})
    time.sleep(0.8)
    card_for(t, f"{name}, a pin you aren't on", a, square)
    card_for(t, f"{name}, the pin you are on", a, square)
    sv.sp("select", id=b); time.sleep(0.4)
    sv.cmd({"do": "press", "code": 13, "chars": "w", "mods": ["cmd"], "letgo": True}); time.sleep(0.8)
    t.ok(f"{name}: ⌘W puts the pin down, asleep", next(x for x in sv.sp("state")["tabs"] if x["id"] == b[:8].lower())["asleep"])
    card_for(t, f"{name}, a pin put down", b, square)
    sv.sp("select", id=a); time.sleep(0.4)
    sv.sp("save"); sv.quit(); sv.launch(); time.sleep(1)
    tabs = {x["url"].rsplit("/", 1)[-1]: x for x in sv.sp("state")["tabs"]}
    asleep = [n for n in ("a", "b") if tabs[n]["asleep"]]
    awake = [n for n in ("a", "b") if not tabs[n]["asleep"]]
    t.ok(f"{name}: after a relaunch, a pin asleep and a pin awake", asleep and awake, (asleep, awake))
    for n in asleep: card_for(t, f"{name}, brought back asleep", tabs[n]["id"], square)
    for n in awake: card_for(t, f"{name}, brought back awake", tabs[n]["id"], square)
    sv.quit()


def main():
    t = sv.T()
    try:
        run(t, "square in the column", {"sidebar": True}, square=True)
        run(t, "row in the column", {"sidebar": True, "pins.list": True}, listed=True)
        run(t, "row in a pin folder", {"sidebar": True}, folder=True)
        run(t, "square in the top row", {"sidebar": False})
        states(t, "square", {"sidebar": True, "spaces": True}, square=True)
        states(t, "row", {"sidebar": True, "pins.list": True}, listed=True)
        states(t, "folder row", {"sidebar": True}, folder=True)
        states(t, "column of icons", {"sidebar": True, "sidebar.icons": True}, square=True)
        states(t, "top row", {"sidebar": False})
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
