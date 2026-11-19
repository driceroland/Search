#!/usr/bin/env python3
"""Back from a single-page app's post to its feed (idea 748).

Build first (`./build.sh debug`), then `python3 Tests/spa_swipe_back.py`.
Same harness as `Tests/zoom_swipe_back.py`: a probe started hidden, in a
world of its own, driven through the bench, nothing made or shown,
everything removed afterwards.

Reddit and X open a post from the feed with history.pushState and go back
with a popstate. Here a local page does the same, in the ways those sites
do it, and each is left by a swipe back, by ⌘[ and by Back (the button and
⌘[ are the same Browser.back()). After each: the feed is on screen, at its
own address, and Back is lit exactly when there is somewhere to go back to.
"""
import json
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("spa-swipe-back")

# One page for every address under /app: a feed, and a post shown in place
# of it. VARIANT says how the post is opened.
APP = """<!doctype html><meta charset=utf-8><title>feed</title>
<style>body{margin:0;font:14px system-ui} a{display:block;padding:40px;font-size:30px}</style>
<div id=view></div>
<script>
var V = new URLSearchParams(location.search).get('v') || 'plain';
var Q = '?v=' + V;
function render() {
  var post = /\\/post\\//.test(location.pathname);
  document.title = post ? 'post' : 'feed';
  document.getElementById('view').innerHTML = post
    ? '<h1 id=post>the post</h1><a id=close href="/app' + Q + '">close</a>'
    : '<h1 id=feed>the feed</h1><a id=open href="/app/post/1' + Q + '">a post</a>';
}
function open(url) {
  if (V === 'timeout') {
    setTimeout(function () { history.pushState({ post: 1 }, '', url); render(); }, 50);
  } else if (V === 'replace') {
    history.pushState({ post: 1 }, '', url); render();
    history.replaceState({ post: 1, seen: true }, '', url + '&ref=feed');
  } else if (V === 'navigation' && window.navigation) {
    navigation.navigate(url);
  } else {
    history.pushState({ post: 1 }, '', url); render();
  }
}
if (V === 'navigation' && window.navigation) {
  navigation.addEventListener('navigate', function (e) {
    if (!e.canIntercept || e.hashChange) return;
    e.intercept({ handler: function () { render(); } });
  });
}
document.addEventListener('click', function (e) {
  var a = e.target.closest && e.target.closest('a');
  if (!a) return;
  e.preventDefault();
  if (a.id === 'close' && V === 'modal') { history.back(); return; }
  open(a.getAttribute('href'));
});
window.addEventListener('popstate', render);
// X sends / to /home as it starts, with no click; Reddit settles its own
// address the same way.
if (V === 'loadpush' && !/\\/post\\//.test(location.pathname)) history.pushState({}, '', '/app/home' + Q);
if (V === 'replace' || V === 'modal') history.replaceState({ feed: 1 }, '', location.href);
render();
</script>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = APP.encode()
        self.send_response(200); self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def log_message(self, *a): pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://localhost:{srv.server_port}"

t = sv.T()


def ev(id, js): return sv.cmd({"do": "eval", "id": id, "js": js}).get("value")


def state(id):
    v = ev(id, "JSON.stringify([location.pathname, document.title, history.length])")
    return json.loads(v) if v else None


def can_back(id):
    return next(x["canBack"] for x in sv.sp("state")["tabs"] if x["id"] == id)


def back(id, how):
    if how == "swipe":
        sv.cmd({"do": "wheel", "id": id, "dx": 300, "dy": 0, "steps": 10, "ms": 150})
    else:
        sv.cmd({"do": "select", "id": id})
        sv.cmd({"do": "press", "code": 33, "chars": "[", "mods": ["cmd"]})


VARIANTS = ["plain", "replace", "timeout", "modal", "loadpush", "navigation"]
HOWS = ["swipe", "key"]


def run(variant, how):
    tab = sv.cmd({"do": "open", "url": f"{BASE}/app?v={variant}"})["id"]
    sv.cmd({"do": "wait", "id": tab, "seconds": 5}); time.sleep(0.6)
    start = state(tab)
    before = can_back(tab)
    sv.cmd({"do": "tap", "id": tab, "selector": "#open"}); time.sleep(2)
    away = state(tab)
    away_back = can_back(tab)
    back(tab, how); time.sleep(1.5)
    got = state(tab)
    after = can_back(tab)
    sv.cmd({"do": "close", "id": tab}); time.sleep(0.3)
    return start, before, away, away_back, got, after


def main():
    only = sys.argv[1:]
    try:
        sv.setup(); sv.launch()
        sv.cmd({"do": "ui", "swipepages": True}); time.sleep(0.3)
        for variant in VARIANTS:
            if only and variant not in only: continue
            for how in HOWS:
                start, before, away, away_back, got, after = run(variant, how)
                print(f"    {variant:10} {how:5} start={start} canBack={before}  post={away} canBack={away_back}  back={got} canBack={after}")
                t.ok(f"{variant}, {how}: the post opened", away and away[1] == "post", away)
                t.ok(f"{variant}, {how}: Back lit on the post", away_back, away_back)
                t.ok(f"{variant}, {how}: back on the feed", got and got[1] == "feed" and "/post/" not in got[0], got)
                t.ok(f"{variant}, {how}: Back as before the post", after == before, (before, after))
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
