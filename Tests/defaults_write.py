#!/usr/bin/env python3
"""The look and layout follow `defaults write` while Search runs
(Preferences.followFile), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/defaults_write.py`. It uses
split_view.py's harness: started hidden, driven through ./bench's socket,
everything removed afterwards.

Each setting was read once, at launch: `defaults write` to a running Search
changed the file and nothing else, and Settings went on showing the old
value until the next launch. Here the tabs' place (sidebar and
sidebar.position) and the look are written from outside while the app runs,
and read back from it: the place as Settings has it, the look with the
appearance it gives the app. A protection written the same way
(tabs.address) still waits for the next launch, as agreed on #736.
"""
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("defaults-write")

t = sv.T()
def values(): return sv.cmd({"do": "settings", "find": "address"})["values"]
def look(): return (p := sv.cmd({"do": "probe"}))["look"], p["appearance"]
def write(key, kind, value): subprocess.run(["defaults", "write", sv.SUITE, key, kind, value])
def read(key):
    out = subprocess.run(["defaults", "read", sv.SUITE, key], capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 else None
def becomes(get, want, within=3):
    """get() once it is `want`, or the last one seen by `within` seconds."""
    until = time.time() + within
    while (v := get()) != want and time.time() < until: time.sleep(0.1)
    return v
try:
    sv.setup(); sv.launch()
    t.ok("at launch: address on, the Mac's look", (values()["tabs.address"], look()) == (True, ("system", "system")))
    write("sidebar", "-bool", "true"); write("sidebar.position", "-string", "right")
    t.ok("the tabs' place written from outside moves", becomes(lambda: values()["tabs.layout"], "right") == "right",
         values()["tabs.layout"])
    write("look", "-string", "dark")
    t.ok("a look written from outside moves, and the app goes dark",
         becomes(look, ("dark", "NSAppearanceNameDarkAqua")) == ("dark", "NSAppearanceNameDarkAqua"), look())
    write("tabs.address", "-bool", "false"); time.sleep(2)
    t.ok("a protection written from outside waits for the next launch",
         (values()["tabs.address"], read("tabs.address")) == (True, "0"), (values()["tabs.address"], read("tabs.address")))
    # The switch still writes the file, and what it wrote isn't read back
    # over: the value the app puts back is the one already there.
    sv.cmd({"do": "ui", "side": "left"}); time.sleep(1.5)
    t.ok("the place chosen in the app stays, in the app and the file",
         (values()["tabs.layout"], read("sidebar.position")) == ("left", "left"),
         (values()["tabs.layout"], read("sidebar.position")))
    subprocess.run(["defaults", "delete", sv.SUITE, "look"])
    t.ok("a line taken out puts the default back, and stays out",
         (becomes(look, ("system", "system")), read("look")) == (("system", "system"), None), (look(), read("look")))
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
