#!/usr/bin/env python3
"""Keys typed while a question hangs from the window stay with the question.

Build first, then `python3 Tests/dialog_keys.py`. A folder of two made-up
bookmarks is brought in, the bookmarks panel opened, and the folder's Remove
asked, as its row's Remove asks: "Remove “Folder”?" hangs from the window.
Esc typed there is the question's. The window's own Escape closes the panel
in front, and used to take the key first: the panel went, and the question
stayed up with Return still on Remove. (That Esc then cancels the question is
AppKit's, and needs the question to be the key window, which a probe started
hidden never has: checked by hand.)
"""
import os
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# Its own world, apart from the split suite's in this checkout (see use()).
sv.use("dialog-keys")

export = tempfile.NamedTemporaryFile("w", suffix=".html", delete=False)
export.write("""<!DOCTYPE NETSCAPE-Bookmark-file-1>
<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
<TITLE>Bookmarks</TITLE>
<H1>Bookmarks</H1>
<DL><p>
    <DT><H3>Reading</H3>
    <DL><p>
        <DT><A HREF="https://one.example/">One</A>
        <DT><A HREF="https://two.example/">Two</A>
    </DL><p>
</DL><p>
""")
export.close()


def bring_in():
    return sv.cmd({"do": "import-file", "path": export.name})


def main():
    t = sv.T()
    try:
        sv.setup(); sv.launch()
        took = bring_in()
        t.ok("a folder of two bookmarks brought in", took.get("bookmarks") == 2, took)

        sv.cmd({"do": "ui", "bookmarks": True}); time.sleep(0.5)
        asked = sv.cmd({"do": "remove-folder", "title": "Reading"}); time.sleep(0.8)
        st = sv.cmd({"do": "probe"})
        t.ok("asked: the question is up over the panel", asked.get("asked") == "Reading" and st["sheet"] and st["bookmarks"], (asked, st))

        sv.cmd({"do": "press", "code": 53, "chars": "\u001b", "sheet": True}); time.sleep(0.8)
        st = sv.cmd({"do": "probe"})
        t.ok("Esc: the panel under the question stays", st["bookmarks"], st)
        again = bring_in()
        t.ok("Esc: the folder and its bookmarks stay", again.get("bookmarks") == 0 and again.get("already") == 2, again)
    finally:
        os.unlink(export.name)
        t.done(); sv.finish()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
