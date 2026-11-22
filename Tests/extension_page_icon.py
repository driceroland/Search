#!/usr/bin/env python3
"""An extension's own pages wear the extension's icon, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/extension_page_icon.py`.
It runs in split_view.py's test world, with its harness: started hidden,
everything removed afterwards. The extension is a folder made here: a new tab
page, another page, and an icon that is one plain colour, so the tab's icon
can be told from a letter by the colour Bench reports for it.

A tab on an extension's page showed a letter, the first of the extension's
id: icons are only asked of http and https pages, so an extension's never had
one. Chrome shows the extension's icon there, and so does Search now.
"""
import json
import struct
import subprocess
import sys
import tempfile
import time
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("extension-page-icon")

# The icon's one colour, as Bench reports a tab's icon: averaged to one pixel.
COLOUR = (0x2A, 0x9D, 0x5C)


def plain_png(size, rgb):
    """A square PNG of one opaque colour."""
    row = b"\x00" + bytes(rgb + (255,)) * size
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(row * size)) + chunk(b"IEND", b""))


def close(reported, rgb=COLOUR, slack=6):
    """The reported colour is this one, give or take a colour space's rounding."""
    if len(reported) != 6:
        return False
    got = [int(reported[i:i + 2], 16) for i in (0, 2, 4)]
    return all(abs(a - b) <= slack for a, b in zip(got, rgb))


t = sv.T()
work = Path(tempfile.mkdtemp(prefix="search-extension-page-icon-"))
folder = work / "Icon"
folder.mkdir()
for size in (16, 32, 48, 128):
    (folder / f"icon-{size}.png").write_bytes(plain_png(size, COLOUR))
(folder / "manifest.json").write_text(json.dumps({
    "manifest_version": 3, "name": "Page Icon", "version": "1.0",
    "icons": {str(s): f"icon-{s}.png" for s in (16, 32, 48, 128)},
    "chrome_url_overrides": {"newtab": "newtab.html"},
}))
(folder / "newtab.html").write_text("<!doctype html><title>New Tab</title><p>new tab")
(folder / "other.html").write_text("<!doctype html><title>Other</title><p>other")
def installed(): return sv.cmd({"do": "extensions"})["extensions"]
def tab(id): return next(x for x in sv.cmd({"do": "tabs"})["tabs"] if x["id"] == id)
try:
    sv.setup()
    sv.launch()
    a = sv.page("a")
    sv.sp("select", id=a); time.sleep(0.3)
    sv.cmd({"do": "ext-answer", "answer": "yes"})
    sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
    ext = None
    for _ in range(50):
        found = [x for x in installed() if x["name"] == "Page Icon" and x["loaded"]]
        if found: ext = found[0]; break
        time.sleep(0.2)
    t.ok("the extension loads", ext is not None, installed())

    t.ok("a website's tab doesn't wear the extension's icon", not close(tab(a)["icon"]), tab(a))

    sv.cmd({"do": "press", "code": 17, "chars": "t", "mods": ["cmd"]}); time.sleep(2)
    st = sv.sp("state"); new = tab(st["activeID"])
    t.ok("⌘T shows the extension's page", new["id"] != a and new["view"].endswith("/newtab.html"), new)
    t.ok("its tab wears the extension's icon, not a letter", close(new["icon"]), new)

    sv.cmd({"do": "eval", "id": new["id"], "js": "location.href = 'other.html'; 1"}); time.sleep(1.5)
    again = tab(new["id"])
    t.ok("another page of the extension wears it too",
         again["view"].endswith("/other.html") and close(again["icon"]), again)
finally:
    t.done(); sv.finish(); subprocess.run(["rm", "-rf", str(work)])
sys.exit(1 if t.failed else 0)
