#!/usr/bin/env python3
"""A page on this Mac opens the files it links to, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/open_html_file.py`. WebKit
lets a file: page read its own folder only, and dropped a click on a link
out of it before Search was asked: the page stayed put, and only the address
pasted into a new window opened it. Pages are written into the test world's
own folder, links are clicked with real (trusted) clicks, and what each tab
shows is read back. Nothing is drawn.
"""
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("open-html-file")


def tabs():
    return [(x["id"], x.get("url", "")) for x in sv.sp("state")["tabs"]]


def text(tid):
    return sv.ev(tid, "document.body ? document.body.innerText : ''") or ""


def url_of(tid):
    return next((u for i, u in tabs() if i == tid), "")


def main():
    t = sv.T()
    try:
        sv.setup()
        root = Path(sv.SUPPORT) / "files"
        # a/ three folders down, so b/ is out of the page's reach, which
        # goes two folders up (#1342): what is tested is Search opening it.
        here = root / "x" / "y" / "a"
        here.mkdir(parents=True, exist_ok=True)
        (root / "b").mkdir(exist_ok=True)
        target = root / "b" / "target.html"
        target.write_text("<title>target</title>TARGET PAGE")
        (here / "same.html").write_text("<title>same</title>SAME FOLDER")
        index = here / "index.html"
        index.write_text(f"""<title>index</title>
<a id=same href="same.html">same</a><br>
<a id=other href="../../../b/target.html">other</a><br>
<a id=blank target=_blank href="{target.as_uri()}">blank</a><br>
<a id=jump href="#down">jump</a><br>
<a id=keep download href="../../../b/target.html">keep</a>
<div style="height:3000px"></div><p id=down>down</p>""")

        class H(BaseHTTPRequestHandler):
            def do_GET(self):
                body = f'<a id=file href="{target.as_uri()}">file</a>'.encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *a):
                pass

        srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        sv.launch()

        def page():
            tid = sv.sp("open", url=index.as_uri())["resultID"]
            time.sleep(1.2)
            return tid

        # A link from another app, the way macOS hands a file over.
        sv.cmd({"do": "windows", "action": "link", "url": target.as_uri()})
        time.sleep(1.5)
        shown = [i for i, u in tabs() if u.endswith("/b/target.html")]
        t.ok("an .html handed over by another app opens", shown and "TARGET PAGE" in text(shown[0]), tabs())

        tid = page()
        sv.cmd({"do": "tap", "id": tid, "selector": "#same"})
        time.sleep(1.5)
        t.ok("a link to a file in the same folder opens", "SAME FOLDER" in text(tid), (url_of(tid), text(tid)))

        tid = page()
        sv.cmd({"do": "tap", "id": tid, "selector": "#other"})
        time.sleep(1.5)
        t.ok("a link to a file in another folder opens, in the tab", url_of(tid).endswith("/b/target.html") and "TARGET PAGE" in text(tid), (url_of(tid), text(tid)))
        sv.cmd({"do": "eval", "id": tid, "js": "history.back(); 1"})
        time.sleep(1.5)
        t.ok("Back returns to the page with the link", url_of(tid).endswith("/a/index.html") and "other" in text(tid), (url_of(tid), text(tid)))

        tid = page()
        before = {i for i, _ in tabs()}
        sv.cmd({"do": "tap", "id": tid, "selector": "#blank"})
        time.sleep(1.5)
        new = [(i, u) for i, u in tabs() if i not in before]
        t.ok("target=_blank to another folder opens one new tab", len(new) == 1 and new[0][1].endswith("/b/target.html") and "TARGET PAGE" in text(new[0][0]), new)
        t.ok("and the page with the link stays", url_of(tid).endswith("/a/index.html"), url_of(tid))

        tid = page()
        sv.ev(tid, "window.__mark = 7; 1")
        sv.cmd({"do": "tap", "id": tid, "selector": "#jump"})
        time.sleep(1)
        t.ok("a jump within the page stays in the page", sv.ev(tid, "String(window.__mark)") == "7" and url_of(tid).endswith("#down"), url_of(tid))

        tid = page()
        sv.cmd({"do": "eval", "id": tid, "js": "document.querySelector('#other').click(); 1"})
        time.sleep(1.5)
        t.ok("a click the page makes itself opens nothing", url_of(tid).endswith("/a/index.html"), url_of(tid))

        tid = page()
        sv.cmd({"do": "tap", "id": tid, "selector": "#keep"})
        time.sleep(1.5)
        t.ok("a download link is left to WebKit", url_of(tid).endswith("/a/index.html"), url_of(tid))

        tid = sv.sp("open", url=f"http://127.0.0.1:{srv.server_port}/")["resultID"]
        time.sleep(1.2)
        before = {i for i, _ in tabs()}
        sv.cmd({"do": "tap", "id": tid, "selector": "#file"})
        time.sleep(1.5)
        t.ok("a website's link to a file stays refused, as in every browser",
             url_of(tid).startswith("http://") and {i for i, _ in tabs()} == before, tabs())
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
