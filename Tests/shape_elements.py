#!/usr/bin/env python3
"""Moving and resizing with Hide Elements (⇧⌘H, Curtain.swift), with
Settings › Browsing › Pages › Move and resize with Hide Elements on: a drag
on the outlined thing moves it, a drag from near its right or bottom edge
resizes it, and either is kept for the site, back after a reload. A plain
click still hides. Off, as it is unless turned on, a press hides at once
and a drag moves nothing. In a hidden probe.

Build first (`./build.sh`), then `python3 Tests/shape_elements.py`. The
same harness as hide_elements.py: the pointer's moves and presses are the
events the page gets from them, sent in Search's own world.
"""
import json
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("shape-elements")

PAGE = ("<div id=box style='position:absolute;left:100px;top:100px;width:200px;height:100px;"
        "background:#fc0'></div><p>text</p>")


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = f"<!doctype html><title>shape</title>{PAGE}".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"

t = sv.T()


def ev(tab, js, world=None):
    req = {"do": "eval", "id": tab, "js": js}
    if world:
        req["world"] = world
    return sv.cmd(req).get("value")


def hiding(on): sv.cmd({"do": "ui", "hiding": on}); time.sleep(0.3)


# A drag from (x, y) inside #box by (dx, dy), as the picker reads one:
# the pointer coming to rest, the press, moves, and the button coming up.
DRAG = """(function (fx, fy, dx, dy) {
  var r = document.getElementById('box').getBoundingClientRect();
  var x = r.left + fx * r.width, y = r.top + fy * r.height;
  document.dispatchEvent(new MouseEvent('mousemove', {clientX: x, clientY: y, bubbles: true}));
  var under = document.elementFromPoint(x, y);
  under.dispatchEvent(new PointerEvent('pointerdown', {clientX: x, clientY: y, bubbles: true, cancelable: true}));
  for (var i = 1; i <= 5; i++)
    document.dispatchEvent(new PointerEvent('pointermove', {clientX: x + dx * i / 5, clientY: y + dy * i / 5, bubbles: true, cancelable: true}));
  under.dispatchEvent(new PointerEvent('pointerup', {clientX: x + dx, clientY: y + dy, bubbles: true, cancelable: true}));
  return true;
})(%s, %s, %s, %s)"""

BOX = ("(function () { var el = document.getElementById('box'), r = el.getBoundingClientRect(); "
       "return [Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height), "
       "getComputedStyle(el).display]; })()")


def kept():
    time.sleep(0.8)
    try:
        return json.load(open(f"{sv.SUPPORT}/hidden.json")).get("127.0.0.1", [])
    except (OSError, ValueError):
        return []


def drag(tab, fx, fy, dx, dy):
    hiding(True)
    ev(tab, DRAG % (fx, fy, dx, dy), world="search")
    time.sleep(1.2)  # the rule arrives, the hand's own styles go
    hiding(False)


SHAPING = {"hiding.shapes": True}


def case_move_and_resize(t):
    """moved by a drag, resized from its corner, both kept after a reload"""
    sv.setup(sidebar=True, **SHAPING); sv.launch()
    tab = sv.sp("open", url=f"{BASE}/")["resultID"]
    time.sleep(1.5)
    left, top, width, height, _ = ev(tab, BOX)
    drag(tab, 0.5, 0.5, 60, 30)
    box = ev(tab, BOX)
    t.ok("moved 60 across and 30 down", box[0] == left + 60 and box[1] == top + 30, box)
    t.ok("not hidden", box[4] != "none", box)
    t.ok("listed as moved", [v.get("label", "").startswith("Moved") for v in kept()] == [True], kept())
    drag(tab, 0.99, 0.98, 40, 20)
    box = ev(tab, BOX)
    t.ok("resized from its corner", box[2] == width + 40 and box[3] == height + 20, box)
    t.ok("still where it was moved", box[0] == left + 60 and box[1] == top + 30, box)
    t.ok("one entry, moved and resized", len(kept()) == 1 and kept()[0]["label"].startswith("Moved and resized"), kept())
    ev(tab, "location.reload()"); time.sleep(1.5)
    t.ok("both kept after a reload", ev(tab, BOX)[:4] == [left + 60, top + 30, width + 40, height + 20], ev(tab, BOX))


def case_click_still_hides(t):
    """a press that does not move is still a click: it hides"""
    sv.setup(sidebar=True, **SHAPING); sv.launch()
    tab = sv.sp("open", url=f"{BASE}/")["resultID"]
    time.sleep(1.5)
    drag(tab, 0.5, 0.5, 0, 0)
    t.ok("hidden", ev(tab, BOX)[4] == "none", ev(tab, BOX))


def case_off_by_default(t):
    """switch untouched: the press hides at once, the drag moves nothing"""
    sv.setup(sidebar=True); sv.launch()
    tab = sv.sp("open", url=f"{BASE}/")["resultID"]
    time.sleep(1.5)
    drag(tab, 0.5, 0.5, 60, 30)
    t.ok("hidden, not moved", ev(tab, BOX)[4] == "none", ev(tab, BOX))
    t.ok("kept as hidden", [v.get("shape") for v in kept()] == [None] and
         not kept()[0]["label"].startswith("Moved"), kept())


def main():
    for case in [case_move_and_resize, case_click_still_hides, case_off_by_default]:
        print(f"- {case.__doc__}")
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
