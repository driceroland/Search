#!/usr/bin/env python3
"""A picture inside a link keeps Open Link in New Tab (idea 1208), in a
hidden probe. No menu is ever shown.

Build first (`./build.sh`), then `python3 Tests/picture_link_menu.py`.
The page script's view of a right-click on a picture is read from
`__officeImagesDecide`, in Search's world, on synthetic events: a link in a
closed shadow root is out of its sight, which is why WebKit's own hit test
decides. Then the menu itself, as PageView makes it from WebKit's
(PictureMenu.shape, the bench's `picturemenu`), from WebKit's items given as
identifiers rather than from a menu WebKit put up.
"""
import struct
import sys
import threading
import time
import zlib
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("picture-link-menu")
def png(w, h):
    raw = b"".join(b"\x00" + bytes((x * 7 + y * 13) % 256 for x in range(w * 3)) for y in range(h))
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


PNG = png(8, 8)
PAGE = b"""<!doctype html><body>
<a href="/plain"><img id=plain src="/p.png" width=40 height=40></a>
<a href="/deep"><div><picture><img id=deep src="/p.png" width=40 height=40></picture></div></a>
<img id=loose src="/p.png" width=40 height=40>
<x-card><img id=slotted src="/p.png" width=40 height=40></x-card>
<script>
customElements.define('x-card', class extends HTMLElement {
  constructor() { super(); this.attachShadow({ mode: 'closed' }).innerHTML = '<a href="/closed"><slot></slot></a>'; }
});
</script>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body, kind = (PNG, "image/png") if self.path.endswith(".png") else (PAGE, "text/html")
        self.send_response(200); self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def log_message(self, *a): pass


DECIDE = """
(function () { var out = {};
  ['plain', 'deep', 'loose', 'slotted'].forEach(function (id) {
    var f = function (e) { out[id] = window.__officeImagesDecide(e); };
    document.addEventListener('contextmenu', f, true);
    document.getElementById(id).dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, composed: true, cancelable: true }));
    document.removeEventListener('contextmenu', f, true);
  });
  return JSON.stringify(out); })()
"""
LINK = ["WKMenuItemIdentifierOpenLink", "WKMenuItemIdentifierOpenLinkInNewWindow",
        "WKMenuItemIdentifierDownloadLinkedFile", "WKMenuItemIdentifierCopyLink"]
IMAGE = ["WKMenuItemIdentifierOpenImageInNewWindow", "WKMenuItemIdentifierDownloadImage", "WKMenuItemIdentifierCopyImage"]


def main():
    import json
    t = sv.T()
    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{srv.server_port}"
    try:
        sv.setup(); sv.launch()
        a = sv.sp("open", url=f"{base}/page")["resultID"]; time.sleep(1.5)
        said = json.loads(sv.cmd({"do": "eval", "id": a, "js": DECIDE, "world": "search"})["value"])
        t.ok("the script sees a link around a picture", said["plain"]["linked"] and said["deep"]["linked"], said)
        t.ok("and none around a loose one", said["loose"]["linked"] is False and said["loose"]["src"].endswith("/p.png"), said)
        t.ok("a link in a closed shadow root is out of its sight", said["slotted"]["linked"] is False, said)
        t.ok("the page can't read the script's verdict",
             sv.ev(a, "typeof window.__officeImagesDecide") == "undefined")

        src = f"{base}/p.png"
        def menu(items, keep=False):
            return sv.cmd({"do": "picturemenu", "id": a, "items": items, "src": src, "keep": keep})
        m = menu(LINK + IMAGE)
        t.ok("WebKit's menu over a picture in a link keeps Open Link in New Tab",
             not m["replaced"] and "OpenLinkInNewWindow" in m["titles"] and "CopyLink" in m["titles"], m)
        t.ok("…its Copy Image and Download Image done by Search", sorted(m["retargeted"]) == ["CopyImage", "DownloadImage"], m)
        m = menu(IMAGE)
        t.ok("over a picture alone: Search's picture menu",
             m["replaced"] and m["titles"][:1] == ["Open Image in New Tab"] and "Copy Image Address" in m["titles"], m)
        m = menu(IMAGE, keep=True)
        t.ok("with an extension's right-click items about: WebKit's", not m["replaced"] and m["titles"][0] == "OpenImageInNewWindow", m)
        m = menu(["WKMenuItemIdentifierOpenLinkInNewWindow", "WKMenuItemIdentifierCopyLink"])
        t.ok("a link alone: untouched", not m["replaced"] and m["titles"] == ["OpenLinkInNewWindow", "CopyLink"], m)
    finally:
        srv.shutdown()
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
