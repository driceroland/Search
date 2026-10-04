#!/usr/bin/env python3
"""Typed file paths use the real address field and existing file loader (#523).

Run ./build.sh debug, then python3 Tests/local_paths.py. Uses a hidden test world.
"""
import sys
import tempfile
from pathlib import Path
from urllib.parse import unquote, urlparse

import split_view as sv

sv.use("local-paths")


def main():
    t = sv.T()
    try:
        sv.setup(); sv.launch()
        tab = sv.page("before-file")
        with tempfile.TemporaryDirectory(dir=sv.ROOT / "build") as directory:
            folder = Path(directory)
            file = folder / "résumé #1? 100%.html"
            file.write_text('<!doctype html><link rel="stylesheet" href="style.css"><p>Local fixture</p><a href="next.html">Next</a>')
            (folder / "next.html").write_text('<!doctype html><p>Next local page</p>')
            (folder / "style.css").write_text("body { color: rgb(12, 34, 56); }")
            paths = [str(file)]
            if file.is_relative_to(Path.home()):
                paths.append("~/" + str(file.relative_to(Path.home())))
            for path in paths:
                sv.sp("select", id=tab)
                sv.cmd({"do": "field", "text": path, "go": True})
                loaded = sv.cmd({"do": "wait", "id": tab})
                t.ok("file finishes loading", not loaded.get("loading") and not loaded.get("failure"), loaded)
                page = sv.cmd({"do": "text", "id": tab})
                url = urlparse(page["url"])
                t.ok("typed path opens the file, not a search", url.scheme == "file" and Path(unquote(url.path)).samefile(file) and "Local fixture" in page["text"], page)
                style = sv.cmd({"do": "eval", "id": tab, "js": "getComputedStyle(document.body).color"})
                t.ok("the existing loader keeps adjacent styles", style["value"] == "rgb(12, 34, 56)", style)
            sv.cmd({"do": "tap", "id": tab, "selector": "a"})
            sv.cmd({"do": "wait", "id": tab})
            page = sv.cmd({"do": "text", "id": tab})
            t.ok("relative links stay local", page["url"].endswith("/next.html") and "Next local page" in page["text"], page)
            sv.cmd({"do": "press", "code": 123, "chars": "\uf702", "mods": ["cmd"]})
            sv.cmd({"do": "wait", "id": tab})
            t.ok("Back returns to the typed file", "Local fixture" in sv.cmd({"do": "text", "id": tab})["text"])
            # Search keeps only web addresses in its session, including before this fix.
            sv.sp("save")
            t.ok("local paths stay out of the saved session", not any(item["url"].startswith("file:") for item in sv.session()["tabs"]))
            sv.quit(); sv.launch()
            t.ok("restart keeps the existing web-only session policy", not any(item["url"].startswith("file:") for item in sv.sp("state")["tabs"]))
    finally:
        t.done(); sv.finish()
    return bool(t.failed)


if __name__ == "__main__":
    sys.exit(main())
