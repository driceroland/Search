#!/usr/bin/env python3
"""Settings › Tabs › Pins stay on their site (#577).

Build first (`./build.sh`), then `python3 Tests/pin_peek.py`. It uses the
split suite's harness: started hidden, no window made or shown, everything
removed afterwards. 127.0.0.1 and localhost serve the same pages and stand
for two sites; /hop on a server of the pin's own site sends the link on
to the other, as google.com/goto does.
"""
import subprocess
import threading
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("pin-peek")

t = sv.T()
OTHER = sv.BASE.replace("127.0.0.1", "localhost")
class Hop(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(302); self.send_header("Location", f"{OTHER}{self.path.replace('/hop', '', 1)}"); self.send_header("Content-Length", "0"); self.end_headers()
    def log_message(self, *a): pass
hops = ThreadingHTTPServer(("127.0.0.1", 0), Hop); threading.Thread(target=hops.serve_forever, daemon=True).start()
HOP = f"http://127.0.0.1:{hops.server_port}/hop"
def pin(id): return sv.cmd({"do": "pin", "id": id})
def follow(id, href, blank=False):
    target = "a.target = '_blank';" if blank else ""
    sv.ev(id, f"var a = document.createElement('a'); a.href = '{href}'; {target} document.body.appendChild(a); a.click(); true")
    time.sleep(1.2)
def peek(): return sv.cmd({"do": "probe"})["peek"]
def close(): sv.cmd({"do": "peek", "url": "close"}); time.sleep(0.5)

try:
    sv.setup(sidebar=True, **{"pins.peek": True, "pins.list": True}); sv.launch()
    a = sv.page("home"); pin(a); sv.sp("select", id=a); time.sleep(0.5)

    follow(a, f"{OTHER}/out")
    t.ok("a link from a pin to another site opens in a peek", peek().endswith("/out"), peek())
    t.ok("…and the pin wears its icon", sv.cmd({"do": "probe"})["peekFrom"].lower().startswith(a.lower()), (sv.cmd({"do": "probe"})["peekFrom"], a))
    t.ok("…and the pin stays on its page", sv.url(sv.sp("state"), a).endswith("/home"), sv.url(sv.sp("state"), a))
    close()

    follow(a, f"{OTHER}/blank", blank=True)
    st = sv.sp("state")
    t.ok("a target=_blank link from a pin to another site too", peek().endswith("/blank"), peek())
    t.ok("…and no tab is opened for it", not any(x["url"].endswith("/blank") for x in st["tabs"]), [x["url"] for x in st["tabs"]])
    close()

    follow(a, f"{HOP}/via-blank", blank=True)
    st = sv.sp("state")
    t.ok("a target=_blank link within the site, sent on to another, opens in a peek", peek().endswith("/via-blank"), peek())
    t.ok("…and no tab is opened for it", not any(x["url"].endswith("/via-blank") for x in st["tabs"]), [x["url"] for x in st["tabs"]])
    close()

    sv.ev(a, f"var a = document.createElement('a'); a.href = '#'; a.onclick = function (e) {{ e.preventDefault(); window.open('{OTHER}/opened') }}; document.body.appendChild(a); a.click(); true")
    time.sleep(1.2)
    st = sv.sp("state")
    t.ok("window.open on a click in a pin opens in a peek", peek().endswith("/opened"), peek())
    t.ok("…and no tab is opened for it", not any(x["url"].endswith("/opened") for x in st["tabs"]), [x["url"] for x in st["tabs"]])
    close()

    follow(a, f"{sv.BASE}/inner")
    t.ok("a link within the site goes in the pin", peek() == "" and sv.url(sv.sp("state"), a).endswith("/inner"), (peek(), sv.url(sv.sp("state"), a)))

    follow(a, f"{HOP}/sent")
    t.ok("a link sent out of the site by its own server opens in a peek", peek().endswith("/sent"), peek())
    t.ok("…and the pin stays on its page", sv.url(sv.sp("state"), a).endswith("/inner"), sv.url(sv.sp("state"), a))
    info = next(x for x in sv.cmd({"do": "tabs"})["tabs"] if x["id"] == a)
    t.ok("…with no error over it", info["view"].endswith("/inner") and not info.get("failure"), info)
    close()

    # Google's way: the page sends itself after the link when the click
    # didn't take it away.
    sv.ev(a, f"var a = document.createElement('a'); a.href = '{OTHER}/again'; a.onclick = function () {{ setTimeout(function () {{ location.href = a.href }}, 300) }}; document.body.appendChild(a); a.click(); true")
    time.sleep(1.5)
    t.ok("the page sending the pin after a peeked link by script is turned away", peek().endswith("/again") and sv.url(sv.sp("state"), a).endswith("/inner"), (peek(), sv.url(sv.sp("state"), a)))
    close()

    sv.sp("close", id=a); time.sleep(0.5)
    st = sv.sp("state")
    t.ok("⌘W on the pin puts it down at the page it was pinned at", sv.url(st, a).endswith("/home"), sv.url(st, a))
    sv.sp("select", id=a); time.sleep(1.5)
    view = next(x["view"] for x in sv.cmd({"do": "tabs"})["tabs"] if x["id"] == a)
    t.ok("…and wakes there", view.endswith("/home"), view)

    r = sv.page("row"); sv.cmd({"do": "pin", "id": r, "listed": True}); sv.sp("select", id=r); time.sleep(0.5)
    follow(r, f"{OTHER}/from-row")
    t.ok("a pinned row peeks as a square does", peek().endswith("/from-row") and sv.url(sv.sp("state"), r).endswith("/row"), (peek(), sv.url(sv.sp("state"), r)))
    close()
    follow(r, f"{OTHER}/row-blank", blank=True)
    t.ok("…its target=_blank links too", peek().endswith("/row-blank") and not any(x["url"].endswith("/row-blank") for x in sv.sp("state")["tabs"]), peek())
    t.ok("…and wears the peek's icon", sv.cmd({"do": "probe"})["peekFrom"].lower().startswith(r.lower()), sv.cmd({"do": "probe"})["peekFrom"])
    close()
    t.ok("put away, no pin wears it", sv.cmd({"do": "probe"})["peekFrom"] == "")

    b = sv.page("loose"); sv.sp("select", id=b); time.sleep(0.5)
    follow(b, f"{OTHER}/away")
    t.ok("a tab that isn't a pin goes as before", peek() == "" and sv.url(sv.sp("state"), b).endswith("/away"), (peek(), sv.url(sv.sp("state"), b)))

    sv.quit()
    subprocess.run(["defaults", "write", sv.SUITE, "pins.peek", "-bool", "false"])
    sv.launch(); time.sleep(0.5)
    st = sv.sp("state")
    p = next(x["id"] for x in st["tabs"] if x["id"] in st["pins"])
    sv.sp("select", id=p); time.sleep(1.5)
    follow(p, f"{OTHER}/off")
    t.ok("switched off: the pin follows the link", peek() == "" and sv.url(sv.sp("state"), p).endswith("/off"), (peek(), sv.url(sv.sp("state"), p)))
    sv.sp("close", id=p); time.sleep(0.5)
    t.ok("…and ⌘W puts it down where it was", sv.url(sv.sp("state"), p).endswith("/off"), sv.url(sv.sp("state"), p))
except Exception:
    import traceback; traceback.print_exc(); t.failed += 1
finally:
    sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)
