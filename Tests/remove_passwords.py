#!/usr/bin/env python3
"""The passwords panel's Remove All… / Remove N… (#469), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/remove_passwords.py`. It uses
the split suite's harness: started hidden, no window made or shown, everything
removed afterwards. The accounts are made up and kept under this test world's
own label ("Search (remove-passwords)"), never among the ones Search keeps for
the person, and the last step removes whatever is left of them.
"""
import os
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# A world of its own, its socket included: launch() waits on SOCK.
sv.W = "remove-passwords"
sv.SUPPORT = f"{sv.HOME}/Library/Application Support/Search ({sv.W})"
sv.SUITE = f"com.officecommun.search.test.{sv.W}"
sv.SOCK = f"{sv.SUPPORT}/bench.sock"

t = sv.T()
def passwords(**f): r = sv.cmd({"do": "passwords", **f}); time.sleep(0.2); return r
def confirm(yes): sv.cmd({"do": "ui", "confirm": yes})

export = tempfile.NamedTemporaryFile("w", suffix=".csv", delete=False)
export.write("name,url,username,password,note\n"
             "Bank,https://bank.example/,me@example.com,made-up-one,\n"
             "Bank online,https://online.bank.example/,other@example.com,made-up-two,\n"
             "Mail,https://mail.example/,me@example.com,made-up-three,\n")
export.close()

try:
    sv.setup(); sv.launch()
    took = sv.cmd({"do": "import-file", "path": export.name})
    t.ok("three made-up accounts brought in", took.get("kept") == 3, took)
    t.ok("three kept", passwords()["count"] == 3)

    r = passwords(filter="bank")
    t.ok("filtered: two shown", r["shown"] == 2, r)

    confirm(False)
    r = passwords(filter="bank", remove=True)
    t.ok("cancelled: nothing removed", r["count"] == 3, r)

    confirm(True)
    r = passwords(filter="bank", remove=True)
    t.ok("removed: only the two the list showed", r["count"] == 1 and r["shown"] == 0, r)

    r = passwords(filter="", remove=True)
    t.ok("no filter: every one removed", r["count"] == 0, r)

    # The real question, as a person gets it. Return is Cancel's, so a
    # keystroke never removes them all. Esc is the question's, not the
    # window's: the window's own Escape closes the panel, and used to take the
    # key first, leaving the question up. Cancel gave Esc up for Return, and
    # the question catches it itself, so it answers even in a probe started
    # hidden, where the question is never the key window.
    sv.cmd({"do": "import-file", "path": export.name})
    sv.cmd({"do": "ui", "passwords": True}); sv.cmd({"do": "ui", "confirm": "ask"}); time.sleep(0.5)
    sv.cmd({"do": "passwords", "filter": "", "remove": True}); time.sleep(0.8)
    st = sv.cmd({"do": "probe"})
    t.ok("asked: the question is up over the panel", st["sheet"] and st["passwords"], st)
    t.ok("asked: Return is Cancel's", st.get("sheetReturn") == "Cancel", st.get("sheetReturn"))
    sv.cmd({"do": "press", "code": 53, "chars": "\u001b", "sheet": True}); time.sleep(0.8)
    st = sv.cmd({"do": "probe"})
    t.ok("Esc: the question is answered", not st["sheet"], st)
    t.ok("Esc: the panel under the question stays", st["passwords"], st)
    t.ok("Esc: nothing removed", passwords()["count"] == 3)
finally:
    # Whatever the test got to, none of its made-up accounts stay behind.
    try:
        confirm(True); passwords(filter="", remove=True)
    except Exception:
        pass
    os.unlink(export.name)
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
