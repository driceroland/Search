#!/usr/bin/env python3
"""Settings › Keyboard & Mouse › Backspace goes back (idea 1120).

Build first (`./build.sh`), then `python3 Tests/backspace_back.py`. Uses the
split suite's harness: started hidden, no window made or shown, everything
removed afterwards. Keys go to the page as real key events (bench `key`).

Off (as it ships, #1161), ⌫ on a page stays. Found by Settings' search.
Turned on, open pages follow at once: ⌫ goes back, ⇧⌫ forward; ⌫ in a
text field or editable text deletes and stays; ⌥⌫ and ⌘⌫ stay.
"""
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("backspace-back")
t = sv.T()
BS = "\x7f"


def key(id, text, mods=None):
    sv.cmd({"do": "key", "id": id, "text": text, "code": 51, "mods": mods or []}); time.sleep(1.2)


def at(id): return sv.url(sv.sp("state"), id)


try:
    sv.setup(); sv.launch()
    a = sv.page("first"); sv.sp("select", id=a); time.sleep(0.5)
    sv.ev(a, f"location.href = '{sv.BASE}/second'; true"); time.sleep(1.5)
    t.ok("on the second page", at(a).endswith("/second"), at(a))
    found = sv.cmd({"do": "settings", "find": "backspace"})
    t.ok("found by Settings' search", any("keys.backspaceBack" in i["keys"] for i in found["found"]), [i["id"] for i in found["found"]])
    t.ok("off by default", found["values"].get("keys.backspaceBack") is False, found["values"].get("keys.backspaceBack"))

    key(a, BS)
    t.ok("off: ⌫ stays on the page", at(a).endswith("/second"), at(a))

    # Turned on: the page already open follows, no reload.
    sv.cmd({"do": "settings", "set": "keys.backspaceBack", "value": True}); time.sleep(0.5)
    stored = subprocess.run(["defaults", "read", sv.SUITE, "keys.backspaceBack"], capture_output=True, text=True)
    t.ok("kept in the settings", stored.stdout.strip() == "1", stored.stdout)
    key(a, BS)
    t.ok("on: ⌫ goes back", at(a).endswith("/first"), at(a))
    key(a, BS, ["shift"])
    t.ok("on: ⇧⌫ goes forward", at(a).endswith("/second"), at(a))
    for mods in (["option"], ["command"]):
        key(a, BS, mods)
        t.ok(f"on: {mods[0]}-⌫ stays", at(a).endswith("/second"), at(a))

    # A new tab, made after, too; then back to the first.
    b = sv.page("third"); sv.sp("select", id=b); time.sleep(0.5)
    sv.ev(b, f"location.href = '{sv.BASE}/fourth'; true"); time.sleep(1.5)
    key(b, BS)
    t.ok("on: a tab opened after goes back as well", at(b).endswith("/third"), at(b))
    sv.sp("select", id=a); time.sleep(0.5)

    sv.ev(a, "document.body.insertAdjacentHTML('beforeend', '<input id=f value=abc><div id=e contenteditable>xyz</div>'); var f = document.getElementById('f'); f.focus(); f.setSelectionRange(3, 3); true")
    key(a, BS)
    t.ok("on: ⌫ in a field deletes and stays", at(a).endswith("/second") and sv.ev(a, "document.getElementById('f').value") == "ab",
         (at(a), sv.ev(a, "document.getElementById('f').value")))
    sv.ev(a, "var e = document.getElementById('e'); e.focus(); getSelection().collapse(e.firstChild, 3); true")
    key(a, BS)
    t.ok("on: ⌫ in editable text deletes and stays", at(a).endswith("/second") and sv.ev(a, "document.getElementById('e').textContent") == "xy",
         (at(a), sv.ev(a, "document.getElementById('e').textContent")))
    # Off again: stays.
    sv.ev(a, "document.activeElement.blur(); true")
    sv.cmd({"do": "settings", "set": "keys.backspaceBack", "value": False}); time.sleep(0.5)
    key(a, BS)
    t.ok("off again: ⌫ stays", at(a).endswith("/second"), at(a))
finally:
    sv.finish()
t.done()
sys.exit(1 if t.failed else 0)
