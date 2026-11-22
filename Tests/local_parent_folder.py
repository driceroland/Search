#!/usr/bin/env python3
"""A page opened from disk reads its styles from a folder or two up
(lessons/one.html → ../assets/style.css), never three (idea 864, #1342).

Build first (`./build.sh`), then `python3 Tests/local_parent_folder.py`.
Hidden test world; the files live under ~/Library/Caches, since WebKit
reads anything under the temporary folders, which would prove nothing.
"""
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("local-parent")
t = sv.T()
COLOR = "getComputedStyle(document.querySelector('p')).color"
with tempfile.TemporaryDirectory(dir=Path.home() / "Library" / "Caches") as d:
    root = Path(d) / "site"
    for sub in ("lessons", "assets", "a/b/c"):
        (root / sub).mkdir(parents=True)
    (root / "assets" / "style.css").write_text("p{color:rgb(12,34,56)}")
    (root / "a" / "two.css").write_text("p{color:rgb(1,2,3)}")
    (root / "lessons" / "one.html").write_text('<!doctype html><link rel=stylesheet href="../assets/style.css"><p>lesson</p>')
    (root / "a" / "b" / "c" / "two.html").write_text('<!doctype html><link rel=stylesheet href="../../two.css"><p>two up</p>')
    (root / "a" / "b" / "c" / "three.html").write_text('<!doctype html><link rel=stylesheet href="../../../assets/style.css"><p>three up</p>')
    try:
        sv.setup(); sv.launch()
        def color(path):
            id = sv.cmd({"do": "open", "url": (root / path).as_uri()})["id"]
            time.sleep(2)
            return sv.ev(id, COLOR)
        c = color("lessons/one.html")
        t.ok("a style one folder up is read", c == "rgb(12, 34, 56)", c)
        c = color("a/b/c/two.html")
        t.ok("a style two folders up is read", c == "rgb(1, 2, 3)", c)
        c = color("a/b/c/three.html")
        t.ok("three folders up stays out of reach", c == "rgb(0, 0, 0)", c)
    finally:
        t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
