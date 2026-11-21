#!/usr/bin/env python3
"""Reddit's promoted posts hidden by Shield (Shield.swift), on a local
stand-in for Reddit, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/reddit_ads.py`. World of its
own (bld-rd-<checkout>), split_view.py's harness. The test settings make
127.0.0.1 one of Reddit's hosts (`test.redditHosts`); localhost, the same
server, is "another site". The page has a normal post and each kind of
promoted element in its light DOM; the probe counts those on screen.
"""
import subprocess
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bld-rd")

PAGE = b"""<!doctype html><title>feed</title>
<shreddit-feed>
<shreddit-post style="display:block;height:80px">a normal post</shreddit-post>
<shreddit-ad-post class="promotedlink" style="display:block;height:80px">Promoted</shreddit-ad-post>
<shreddit-comments-page-ad style="display:block;height:60px">Promoted</shreddit-comments-page-ad>
<shreddit-sidebar-ad style="display:block;height:60px">Ad</shreddit-sidebar-ad>
<shreddit-dynamic-ad-link style="display:block;height:20px">Ad</shreddit-dynamic-ad-link>
<comment-tree-ad style="display:block;height:20px">Ad</comment-tree-ad>
<shreddit-comment style="display:block;height:40px">a normal comment</shreddit-comment>
<div class="advert-note" style="height:20px">class that merely contains ad</div>
</shreddit-feed>"""

COUNT = """(function(){
 function shown(sel){var n=0;document.querySelectorAll(sel).forEach(function(e){if(e.getBoundingClientRect().height>0)n++});return n}
 return JSON.stringify({ads:shown('shreddit-ad-post,shreddit-comments-page-ad,shreddit-sidebar-ad,shreddit-dynamic-ad-link,comment-tree-ad,.promotedlink'),
   normal:shown('shreddit-post,shreddit-comment,.advert-note')})})()"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(PAGE))); self.end_headers(); self.wfile.write(PAGE)
    def log_message(self, *a): pass

srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
PORT = srv.server_port


def start(shield=True, paused=None):
    sv.setup(shield=shield)
    subprocess.run(["defaults", "write", sv.SUITE, "test.redditHosts", "-array", "127.0.0.1"], check=True)
    if paused:
        subprocess.run(["defaults", "write", sv.SUITE, "shield.paused", "-array", paused], check=True)
    sv.launch()


def counts(host):
    id = sv.cmd({"do": "open", "url": f"http://{host}:{PORT}/"})["id"]
    time.sleep(2.5)
    import json
    return json.loads(sv.ev(id, COUNT) or "{}")


t = sv.T()
try:
    start()
    r = counts("127.0.0.1")
    t.ok("reddit: no promoted element on screen", r.get("ads") == 0, r)
    t.ok("reddit: the normal post, comment and look-alike class stay", r.get("normal") == 3, r)
    o = counts("localhost")
    t.ok("another site: promoted elements untouched", o.get("ads") == 5 and o.get("normal") == 3, o)
    sv.quit()
    start(shield=False)
    r = counts("127.0.0.1")
    t.ok("Shield off: untouched", r.get("ads") == 5, r)
    sv.quit()
    start(paused="127.0.0.1")
    r = counts("127.0.0.1")
    t.ok("Shield paused on the site: untouched", r.get("ads") == 5, r)
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
