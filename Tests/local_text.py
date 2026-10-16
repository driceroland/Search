#!/usr/bin/env python3
"""A text file on this Mac opens as text (#525), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/local_text.py`. Files are
written into the test world's own folder (WebKit only reads a file: page
from a folder the tab may read), opened by their address, and what the tab
shows is read back. Nothing is drawn.
"""
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("local-text")

FILES = {
    "Makefile": (b"all:\n\techo h\xc3\xa9llo\n", "text"),
    "settings.yaml": (b"key: value\nlist:\n  - one\n", "text"),
    "hosts": (b"##\n# Host Database\n127.0.0.1 localhost\n", "text"),
    "evil.txt": (b'<script>window.__ran=1</script><img src=x onerror="window.__ran=2">\n', "text"),
    "blob.bin": (os.urandom(4096) + b"\x00", "download"),
}


def main():
    t = sv.T()
    try:
        sv.setup()
        folder = Path(sv.SUPPORT) / "files"
        folder.mkdir(parents=True, exist_ok=True)
        for name, (data, _) in FILES.items():
            (folder / name).write_bytes(data)
        sv.launch()
        for name, (_, want) in FILES.items():
            tid = sv.sp("open", url=(folder / name).as_uri())["resultID"]
            time.sleep(1.5)
            kind = sv.ev(tid, "document.contentType + ' ' + document.characterSet") or ""
            text = sv.ev(tid, "document.body ? document.body.innerText : ''") or ""
            downloads = os.listdir(Path(sv.SUPPORT) / "Downloads") if (Path(sv.SUPPORT) / "Downloads").exists() else []
            if want == "text":
                t.ok(f"{name}: shown as UTF-8 text", kind == "text/plain UTF-8" and name not in downloads, (kind, downloads))
            else:
                t.ok(f"{name}: downloaded, as before", name in downloads, (kind, downloads))
        t.ok("Makefile's accent reads as one letter", "héllo" in (sv.ev(sv.sp("state")["tabs"][1]["id"], "document.body.innerText") or ""))
        evil = [x for x in sv.sp("state")["tabs"] if x.get("url", "").endswith("evil.txt")]
        if evil:
            t.ok("a file's <script> and onerror run nothing", sv.ev(evil[0]["id"], "String(window.__ran)") == "undefined")
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
