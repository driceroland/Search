#!/usr/bin/env python3
"""A site framed in another asks for its cookies (Storage Access API), in a
hidden probe (idea 745).

Build first (`./build.sh debug`), then `python3 Tests/storage_access.py`. It
uses the split suite's harness in a world of its own (storage-access-…):
started hidden, nothing shown, everything removed afterwards.

Teams on the web shows a channel's Shared tab in a SharePoint frame, another
site, which needs its sign-in cookies there. With Prevent cross-site
tracking on, a framed site gets none until it asks, with
document.requestStorageAccess() on a click, and is let. The stand-in: a
page on 127.0.0.1 framing one from localhost. Asked from a tab behind,
the question waits for it and is dropped if the tab goes to another site
first; asked from a tab whose space was left, it waits for the space.
"""
import json
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("storage-access")

FRAME = """<!doctype html><style>html,body{margin:0;height:100%}button{width:100%;height:100%}</style>
<button id=ask>ask</button>
<script>
function report(step, extra) {
  document.hasStorageAccess().then(has => parent.postMessage(JSON.stringify(Object.assign(
    {step: step, has: has, cookie: document.cookie || ''}, extra || {})), '*'));
}
report('load');
function request() {
  document.requestStorageAccess().then(() => {
    document.cookie = 'plain=1; Path=/';
    fetch('/echo', {credentials: 'include'}).then(r => r.text()).then(sent => report('granted', {sent: sent}));
  }, e => report('refused', {error: String(e)}));
}
// ?later: asked a moment after the click, within the click's say-so, so
// the tab can be put out of sight between the two.
ask.onclick = () => { report('clicked'); location.search == '?later' ? setTimeout(request, 700) : request(); };
</script>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        port = self.server.server_port
        cookie = []
        if self.path.startswith("/top"):
            later = "?later" if self.path.endswith("later") else ""
            body = f"""<!doctype html><script>window.got = []; addEventListener('message', e => window.got.push(JSON.parse(e.data)))</script>
<iframe id=f style="width:400px;height:200px;border:0" src="http://localhost:{port}/frame{later}"></iframe>"""
        elif self.path.startswith("/frame"):
            body = FRAME
        elif self.path == "/first":
            body = "<!doctype html><button id=b style='width:300px;height:100px'>here</button>"
            cookie = [("Set-Cookie", "firstparty=1; Path=/")]
        else:
            body = self.headers.get("Cookie") or "none"
        self.send_response(200); self.send_header("Content-Type", "text/html")
        for k, v in cookie: self.send_header(k, v)
        self.end_headers(); self.wfile.write(body.encode())

    def log_message(self, *a): pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
PORT = srv.server_port


def got(tab, step, within=10):
    for _ in range(within * 4):
        for g in sv.ev(tab, "window.got") or []:
            if g.get("step") == step:
                return g
        time.sleep(0.25)
    return None


def asking():
    return sv.cmd({"do": "probe"}).get("asking", "")


def wait_asking(within=10):
    for _ in range(within * 4):
        asked = asking()
        if asked: return asked
        time.sleep(0.25)
    return ""


def start(top="/top", select=True, **prefs):
    """A fresh world: the framed site visited as a site of its own first, as
    SharePoint has been by anyone signed in to Teams (its sign-in cookie),
    then the page framing it."""
    sv.setup(**prefs); sv.launch()
    first = sv.cmd({"do": "open", "url": f"http://localhost:{PORT}/first"})["id"]
    time.sleep(1.5)
    sv.cmd({"do": "tap", "id": first, "selector": "#b"}); time.sleep(0.5)
    tab = sv.cmd({"do": "open", "url": f"http://127.0.0.1:{PORT}{top}"})["id"]
    # A question is asked over its own page: the tab in front.
    if select: sv.cmd({"do": "select", "id": tab})
    time.sleep(2)
    return first, tab


def run(answer):
    """The frame's cookies asked for and answered `answer` (always|no) →
    what the card asked, the frame's state at load, and after."""
    _, top = start()
    load = got(top, "load")
    sv.cmd({"do": "tap", "id": top, "selector": "#f"})
    asked = wait_asking()
    time.sleep(0.7)  # the card takes no answer in its first half second
    if asked: sv.cmd({"do": "answer", "with": answer})
    after = got(top, "granted", 8) or got(top, "refused", 2)
    print("   ", answer, json.dumps({"asked": asked, "load": load, "after": after}))
    sv.quit()
    return asked, load, after


def held_then_elsewhere(t):
    """Asked from a tab behind, held, and the tab goes to another site
    before you get to it: never asked over the new page."""
    first, top = start(select=False)
    sv.cmd({"do": "tap", "id": top, "selector": "#f"})
    time.sleep(1.5)
    held = sv.sp("state").get("held", {})
    t.ok("behind: the question waits for its tab, not shown over the one in front",
         held.get(top) == 1 and asking() == "", (held, asking()))
    sv.cmd({"do": "go", "id": top, "url": f"http://localhost:{PORT}/first"}); time.sleep(1.5)
    t.ok("behind, gone elsewhere: nothing is waiting for the tab any more", not sv.sp("state").get("held", {}).get(top), sv.sp("state").get("held"))
    sv.cmd({"do": "select", "id": top}); time.sleep(1.5)
    t.ok("behind, gone elsewhere: going to the tab asks nothing", asking() == "", asking())
    sv.quit()


def main():
    t = sv.T()
    try:
        asked, load, after = run("always")
        t.ok("the frame starts without its cookies", load and not load["has"] and "firstparty" not in load["cookie"], load)
        t.ok("a click in the frame asking for them brings up the question, over its page", asked == "localhost cookies", asked)
        t.ok("allowed: the request settles and the frame has access", after and after["step"] == "granted" and after["has"], after)
        t.ok("allowed: the frame's server gets its sign-in cookie", after and "firstparty=1" in after.get("sent", ""), after)
        asked, load, after = run("no")
        t.ok("refused: the request settles as refused, no cookies", after and after["step"] == "refused" and not after["has"]
             and "firstparty" not in after.get("cookie", ""), after)
        held_then_elsewhere(t)
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
