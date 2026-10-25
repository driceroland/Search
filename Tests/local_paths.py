#!/usr/bin/env python3
"""Typed file paths use the real loader and survive session restore (#523, #699).

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
        sv.setup(**{"tabs.groups": True}); sv.launch()
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
                before = sv.cmd({"do": "text", "id": tab})["url"]
                sv.cmd({"do": "field", "text": path, "type": True})
                t.ok("typing leaves the current page alone", sv.cmd({"do": "text", "id": tab})["url"] == before)
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
            sv.cmd({"do": "ui", "edittab": str(folder / "next.html"), "finishedit": True})
            sv.cmd({"do": "wait", "id": tab})
            t.ok("inline address editing opens a local path", "Next local page" in sv.cmd({"do": "text", "id": tab})["text"])
            # A group with only a file must survive too, even after its page sleeps.
            web = sv.page("kept-web")
            grouped = sv.sp("open", url=file.as_uri())["resultID"]
            sv.cmd({"do": "wait", "id": grouped})
            group = sv.sp("group", id=grouped)["groups"][-1]["id"]
            sv.sp("select", id=web)
            slept = sv.sp("sleep", id=grouped)
            t.ok("the grouped file can sleep", slept.get("sleepResult") == "asleep", slept)

            private = folder / "private.html"
            private.write_text("<!doctype html><p>Private local page</p>")
            shy = sv.sp("private")["activeID"]
            sv.cmd({"do": "go", "id": shy, "url": private.as_uri()})
            sv.cmd({"do": "wait", "id": shy})
            bench = folder / "bench.html"
            bench.write_text("<!doctype html><p>Bench local page</p>")
            scripted = sv.sp("bench", url=bench.as_uri())["resultID"]
            sv.cmd({"do": "wait", "id": scripted})
            sv.sp("select", id=web)

            kept = {file.as_uri(), (folder / "next.html").as_uri(), f"{sv.BASE}/kept-web"}
            sv.sp("save")
            saved = sv.session()
            t.ok("ordinary and sleeping local tabs are saved beside web tabs", {e["url"] for e in saved["tabs"]} == kept, saved)
            t.ok("a file-only group is saved with its tab", any(g["id"] == group for g in saved.get("groups") or [])
                 and any(e["url"] == file.as_uri() and e.get("groupID") == group for e in saved["tabs"]), saved)
            t.ok("private and bench file paths are never written", private.as_uri() not in str(saved) and bench.as_uri() not in str(saved), saved)
            sv.quit(); sv.launch()
            state = sv.sp("state")
            t.ok("restart restores both local tabs and the web tab", {e["url"] for e in state["tabs"]} == kept, state["tabs"])
            t.ok("private and bench tabs do not return", not any(e["shy"] or e["bench"] for e in state["tabs"]), state["tabs"])
            restored = next((e for e in state["tabs"] if e["url"] == file.as_uri()), None)
            t.ok("a restored local tab waits to be selected", restored is not None and restored["asleep"] and not restored["built"], restored)
            groups = dict(zip([e["id"] for e in state["tabs"]], state["groupIDs"]))
            t.ok("the file-only group comes back", restored is not None and groups[restored["id"]] == group
                 and any(g["id"] == group for g in state["groups"]), state["groups"])
            sv.sp("save")
            t.ok("saving before waking keeps local tabs", {e["url"] for e in sv.session()["tabs"]} == kept, sv.session())
            if restored:
                sv.sp("select", id=restored["id"])
                loaded = sv.cmd({"do": "wait", "id": restored["id"]})
                t.ok("the restored file loads without a failure", not loaded.get("loading") and not loaded.get("failure"), loaded)
                page = sv.cmd({"do": "text", "id": restored["id"]})
                t.ok("the restored file has its content", "Local fixture" in page["text"], page)
                style = sv.cmd({"do": "eval", "id": restored["id"], "js": "getComputedStyle(document.body).color"})
                t.ok("the restored file can still read its adjacent stylesheet", style["value"] == "rgb(12, 34, 56)", style)
    finally:
        t.done(); sv.finish()
    return bool(t.failed)


if __name__ == "__main__":
    sys.exit(main())
