#!/usr/bin/env python3
"""Shift-Return searches with a second engine (#848), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/shift_return.py`. Uses the
split suite's harness: started hidden in a world of its own, keys pressed
through the app's own event queue, everything removed afterwards. Both
engines are custom ones on the harness's own local server, so nothing
leaves the Mac.

With no engine chosen, Shift-Return is Return, as it always was. With one
chosen, Shift-Return and Shift-Enter on the keypad send exactly what was
typed there, an address included, and ⌘Return is left as it was.
"""
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("shift-return")

MAIN = f"{sv.BASE}/main?q=%s"
SHIFT = f"{sv.BASE}/shift?q=%s"


def press(code, ch, mods=()):
    return sv.cmd({"do": "press", "code": code, "chars": ch, "mods": list(mods)})


def where():
    s = sv.cmd({"do": "suggest"})
    return s["address"] + " " + s["pending"]


def urls():
    return [x.get("url") or "" for x in sv.cmd({"do": "tabs"}).get("tabs", [])]


def type_in_new_tab(text):
    press(17, "t", ["cmd"]); time.sleep(0.5)
    sv.cmd({"do": "field", "text": text}); time.sleep(0.4)


def write(key, value):
    subprocess.run(["defaults", "write", sv.SUITE, key, value])


def main():
    t = sv.T()
    try:
        sv.setup(**{"newtab.floating": False})
        write("search.engine", "custom"); write("search.custom", MAIN)
        sv.launch()

        # Off, as for anyone who never picks an engine.
        type_in_new_tab("red pandas")
        press(36, "\r", ["shift"]); time.sleep(1.0)
        w = where()
        t.ok("off: Shift-Return is Return, the default engine", "/main?q=red%20pandas" in w, w)

        sv.quit()
        write("search.shift", "custom"); write("search.shiftCustom", SHIFT)
        sv.launch()

        type_in_new_tab("red pandas")
        press(36, "\r"); time.sleep(1.0)
        w = where()
        t.ok("Return: still the default engine", "/main?q=red%20pandas" in w, w)

        type_in_new_tab("red pandas")
        press(36, "\r", ["shift"]); time.sleep(1.0)
        w = where()
        t.ok("Shift-Return: the second engine", "/shift?q=red%20pandas" in w, w)

        type_in_new_tab("otters")
        press(76, "\x03", ["shift"]); time.sleep(1.0)
        w = where()
        t.ok("Shift-Enter on the keypad: the second engine", "/shift?q=otters" in w, w)

        # An address typed is searched for as words, not gone to.
        type_in_new_tab("example.com")
        press(36, "\r", ["shift"]); time.sleep(1.0)
        w = where()
        t.ok("Shift-Return on an address: searched, as typed", "/shift?q=example.com" in w, w)

        # ⌘Return: a new tab with the default engine, as before.
        type_in_new_tab("koalas")
        before = len(urls())
        press(36, "\r", ["cmd"]); time.sleep(1.0)
        after = urls()
        t.ok("⌘Return: untouched, a new tab on the default engine",
             len(after) == before + 1 and any("/main?q=koalas" in u for u in after), str(after))

        # The floating new tab, over a page: a tab of its own.
        sv.quit()
        subprocess.run(["defaults", "write", sv.SUITE, "newtab.floating", "-bool", "true"])
        sv.launch()
        sv.cmd({"do": "field", "text": f"{sv.BASE}/start"}); time.sleep(0.3)
        press(36, "\r"); time.sleep(1.0)
        before = len(urls())
        press(17, "t", ["cmd"]); time.sleep(0.5)
        sv.cmd({"do": "field", "text": "wombats"}); time.sleep(0.4)
        press(36, "\r", ["shift"]); time.sleep(1.2)
        after = urls()
        t.ok("floating field: Shift-Return opens the second engine in a tab of its own",
             len(after) == before + 1 and any("/shift?q=wombats" in u for u in after), str(after))
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
