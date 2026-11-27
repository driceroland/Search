#!/usr/bin/env python3
"""Import web bookmarks with mixed-case URL schemes in a hidden probe.

Build first (`./build.sh debug`), then `python3 Tests/bookmarks_import_schemes.py`.
The app imports a synthetic Netscape bookmark file without opening its links.
"""
import json
import sys
import tempfile
from pathlib import Path

import split_view as sv

sv.use("bookmarks-import-schemes")

HTML = """<!DOCTYPE NETSCAPE-Bookmark-file-1>
<DL><p>
    <DT><A HREF="HTTP://example.test/CaseSensitive%2FPath?Q=Value&amp;B=Two#Section">Uppercase HTTP</A>
    <DT><A HREF="hTtPs://example.test/Another%2FPath?Q=Mixed#Heading">Mixed HTTPS</A>
    <DT><A HREF="http://example.test/AlreadyLower">Lowercase HTTP</A>
    <DT><A HREF="https://example.test/AlsoLower">Lowercase HTTPS</A>
    <DT><A HREF="FTP://example.test/bookmark">FTP</A>
    <DT><A HREF="file:///bookmark.html">File</A>
</DL><p>
"""


def main():
    t = sv.T()
    try:
        sv.setup()
        sv.launch()
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "bookmarks.html"
            path.write_text(HTML, encoding="utf-8")
            request = {"do": "import-file", "path": str(path)}
            first = sv.cmd(request)
            t.ok("all four web bookmarks came in", first["bookmarks"] == 4, first)
            t.ok("non-web links were skipped", not {"FTP", "File"}.intersection(first["top"]), first)

            # Look at the actual saved addresses, not just the import count.
            sv.quit()
            saved = json.loads((Path(sv.SUPPORT) / "bookmarks.json").read_text(encoding="utf-8"))
            addresses = {bookmark["title"]: bookmark["url"] for bookmark in saved}
            t.ok("uppercase HTTP keeps the path, query and fragment",
                 addresses.get("Uppercase HTTP") == "http://example.test/CaseSensitive%2FPath?Q=Value&B=Two#Section",
                 addresses)
            t.ok("mixed-case HTTPS keeps the path, query and fragment",
                 addresses.get("Mixed HTTPS") == "https://example.test/Another%2FPath?Q=Mixed#Heading", addresses)
            t.ok("lowercase addresses stay the same",
                 addresses.get("Lowercase HTTP") == "http://example.test/AlreadyLower"
                 and addresses.get("Lowercase HTTPS") == "https://example.test/AlsoLower", addresses)

            sv.launch()
            path.write_text(HTML.replace("HTTP://", "http://").replace("hTtPs://", "https://"), encoding="utf-8")
            again = sv.cmd(request)
            t.ok("reimporting with lowercase schemes keeps one of each bookmark",
                 again["bookmarks"] == 0 and again["already"] == 4 and again["total"] == 4, again)
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
