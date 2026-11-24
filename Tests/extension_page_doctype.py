#!/usr/bin/env python3
"""An extension page keeps its doctype once Search puts its shim in it, so it
renders in standards mode — in a hidden probe, without the network.

Build first (`./build.sh`), then `python3 Tests/extension_page_doctype.py`. A
copy of build/Search.app under a bundle id of its own, hidden, in a world of
its own; the copy, its WebKit folders and the world are removed afterwards.

Search writes `<script src="/search-shim.js">` into every page an extension
ships, after `<head>`. A page with no `<head>` tag got it at the very start,
before its `<!doctype html>`: the doctype was then not the first thing in
the document, and the page rendered in quirks mode (compatMode
"BackCompat"), which can break its layout. Pages of every shape: no head,
no html either, a normal one, a byte order mark, a comment before the
doctype, an uppercase doctype, a `<header>` but no head, and a page an older
Search already prepared with the tag in front. Each must be in standards
mode, carry the shim once, in its head, and have run it before its own
script.
"""
import json
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("extension-page-doctype")
BUNDLE = "com.officecommun.search.pagedoctype"
work = Path(tempfile.mkdtemp(prefix="search-page-doctype-"))

BODY = "<p id=t>café</p><script src=p.js></script>"
PAGES = {
    "nohead.html": f"<!doctype html><html><body>{BODY}</body></html>",
    "nohtml.html": f"<!doctype html><body>{BODY}</body>",
    "normal.html": f"<!doctype html><html lang=en><head><meta charset=utf-8><title>Normal</title></head><body>{BODY}</body></html>",
    "bom.html": f"﻿<!doctype html><body>{BODY}</body>",
    "comment.html": f"<!-- built by a tool -->\n<!doctype html>\n<html><body>{BODY}</body></html>",
    "upper.html": f"<!DOCTYPE HTML>\n<HTML LANG=en>\n<BODY>{BODY}</BODY></HTML>",
    "header.html": f"<!doctype html><html><body><header class=top>Top</header>{BODY}</body></html>",
    # What an earlier Search left in a page with no head: the tag in front.
    "stale.html": f"<script src=\"/search-shim.js\"></script><!doctype html><html><body>{BODY}</body></html>",
}
FILES = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "DoctypePages", "version": "1.0",
        "background": {"service_worker": "sw.js"},
        "action": {"default_popup": "nohead.html"},
        "options_ui": {"page": "nohtml.html", "open_in_tab": True},
    }),
    "sw.js": "chrome.runtime.onInstalled.addListener(() => {});\n",
    # The page's own script: did the shim run before it?
    "p.js": "document.documentElement.dataset.shimFirst = String('__searchKept' in globalThis && typeof chrome.runtime.id === 'string');\n",
    **PAGES,
}

CHECK = """JSON.stringify({
  mode: document.compatMode,
  first: document.documentElement.dataset.shimFirst || null,
  tags: document.querySelectorAll('script[src="/search-shim.js"]').length,
  inHead: !!document.head && !!document.head.querySelector('script[src="/search-shim.js"]'),
  text: (document.getElementById('t') || {}).textContent || null,
  doctype: document.doctype ? document.doctype.name : null
})"""


def probe_copy():
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def main():
    t = sv.T()
    sv.APP = probe_copy()
    try:
        sv.setup()
        sv.launch()
        folder = work / "ext"
        folder.mkdir(parents=True)
        for name, body in FILES.items():
            (folder / name).write_bytes(body.encode("utf-8"))
        sv.cmd({"do": "ext-answer", "answer": "yes"})
        sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
        ext = None
        for _ in range(40):
            ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == "DoctypePages" and x["loaded"]), None)
            if ext: break
            time.sleep(0.5)
        t.ok("the extension loads", ext is not None)
        if not ext: return t
        for name in PAGES:
            page = sv.cmd({"do": "ext-page", "id": ext["id"], "path": name})["id"]
            got = None
            for _ in range(20):
                time.sleep(0.3)
                got = json.loads(sv.ev(page, CHECK) or "null")
                if got and got["first"]: break
            t.ok(f"{name}: standards mode", got and got["mode"] == "CSS1Compat" and got["doctype"] == "html", got)
            t.ok(f"{name}: the shim ran before the page's own script", got and got["first"] == "true", got)
            t.ok(f"{name}: one shim tag, in the head", got and got["tags"] == 1 and got["inHead"], got)
            # The pages that say they are UTF-8: a meta charset, or a byte
            # order mark, which the rewrite must keep.
            if name in ("normal.html", "bom.html"):
                t.ok(f"{name}: its text reads as written", got and got["text"] == "café", got)
        # The page as prepared on disk: a byte order mark stays first.
        prepared = next(Path(sv.SUPPORT).rglob("bom.html"), None)
        raw = prepared.read_bytes() if prepared else b""
        t.ok("the prepared bom.html still starts with its byte order mark, then the doctype",
             raw.startswith(b"\xef\xbb\xbf<!doctype html>"), raw[:60])
    finally:
        sv.finish()
        for kind in ("WebKit", "Caches", "HTTPStorages"):
            shutil.rmtree(Path.home() / "Library" / kind / BUNDLE, ignore_errors=True)
        shutil.rmtree(work, ignore_errors=True)
    return t


if __name__ == "__main__":
    t = main()
    t.done()
    sys.exit(1 if t.failed else 0)
