#!/usr/bin/env python3
"""An extension's popup takes its content's size and follows it, in a hidden probe.

Build first (`./build.sh debug`), then `python3 Tests/extension_popup_follow.py`.
It runs a copy of build/Search.app under a bundle id of its own, hidden, in a
world of its own; the copy, its WebKit folders and the world are removed
afterwards.

Idea 1022: a popup that sets its size from its script after it loads came
up as a narrow strip, then wide; after two seconds the popover only grew, so
a list that got shorter left blank room; and a list hanging out of a body of
fixed height (Shazam's) didn't make it taller. Chrome follows the content
both ways, between 25 × 25 and 800 × 600. Three popups, each measured over
time against what its content spans:

- late: the body's width (380) and a list set by script 0.6 s after load,
  then the list cut to a third at 3 s and made long again at 5 s;
- hang: a body 120 tall with a list positioned under it, to 420;
- huge: content 1200 × 1000, held to 800 × 600 and scrolling;
- after a relaunch, late's popover stands at its last size from the start
  and is never shown as the 25-point square.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("extension-popup-follow")
BUNDLE = "com.officecommun.search.popupfollow"
work = Path(tempfile.mkdtemp(prefix="search-popupfollow-"))

ROWS = "Array.from({length: N}, (_, i) => '<li style=\"height:30px\">Row ' + i + '</li>').join('')"
POPUPS = {
    "late": """<!doctype html><html><head><title>late</title><style>body{margin:0;font:13px system-ui} ul{margin:0;padding:0;list-style:none}</style></head>
<body><ul id=list></ul><script src=late.js></script></body>""",
    "hang": """<!doctype html><html><head><title>hang</title><style>body{margin:0;width:300px;height:120px;position:relative;font:13px system-ui}
#list{position:absolute;top:120px;left:0;width:300px;height:300px;background:#eee}</style></head>
<body><div>Now playing</div><div id=list>History</div></body>""",
    "huge": """<!doctype html><html><head><title>huge</title><style>body{margin:0}</style></head><body><div style="width:1200px;height:1000px">Huge</div></body>""",
}
LATE_JS = f"""
function rows(N) {{ document.getElementById('list').innerHTML = {ROWS}; }}
setTimeout(() => {{ document.body.style.width = '380px'; rows(10); }}, 600);
setTimeout(() => rows(3), 3000);
setTimeout(() => rows(12), 5000);
"""


def probe_copy():
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def popup(id, js):
    try:
        return sv.cmd({"do": "ext-popup", "id": id, "js": js})
    except RuntimeError:
        return None


# What the content spans: the root's scroll size, and the bottom of what
# hangs lowest in the body.
SPAN = ("[document.documentElement.scrollWidth, Math.max(document.documentElement.getBoundingClientRect().height,"
        " ...Array.from(document.body.querySelectorAll('*'), e => e.getBoundingClientRect().bottom + scrollY)), document.compatMode]")


DEBUG = bool(os.environ.get("POPUP_DEBUG"))


def loaded(name, within=60):
    end = time.time() + within
    while time.time() < end:
        ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == name and x["loaded"]), None)
        if ext: return ext
        time.sleep(0.25)
    return None


def watch(id, seconds):
    """The popover's size while its page is in view, sampled every quarter
    second: (t, width, height, content width, content height); 0 × 0 while
    the page is still unseen."""
    out, start = [], time.time()
    while time.time() - start < seconds:
        r = popup(id, SPAN)
        if r and r.get("value"):
            p = r.get("popover") or {}
            w, h = p.get("size", [0, 0]) if p.get("shown") else (0, 0)
            out.append((round(time.time() - start, 2), w, h, *r["value"][:2]))
            if DEBUG: print("   ", out[-1], r["value"][2:])
            # Search adds its shim's <script> at the top of the <head>: the
            # page keeps its doctype, and lays out as Chrome's would.
            assert not p.get("shown") or r["value"][2] == "CSS1Compat", r["value"]
        time.sleep(0.25)
    return out


def at(samples, when):
    """The last sample before `when` seconds."""
    before = [s for s in samples if s[0] <= when]
    return before[-1] if before else None


def near(a, b, slack=3): return a is not None and abs(a - b) <= slack


def main():
    t = sv.T()
    ids = {}
    for name, html in POPUPS.items():
        folder = work / name
        folder.mkdir()
        (folder / "manifest.json").write_text(json.dumps({"manifest_version": 3, "name": f"Follow {name}", "version": "1.0",
                                                          "action": {"default_popup": "popup.html"}}))
        (folder / "popup.html").write_text(html)
        (folder / "late.js").write_text(LATE_JS)
    sv.APP = probe_copy()
    try:
        sv.setup(sidebar=True)
        sv.launch()
        sv.cmd({"do": "ext-answer", "answer": "yes"})
        for name in POPUPS:
            sv.cmd({"do": "ext-folder", "path": str(work / name), "yes": True})
            ext = loaded(f"Follow {name}")
            t.ok(f"{name}: loads", ext is not None)
            if ext:
                ids[name] = ext["id"]
                sv.cmd({"do": "ext-pin", "id": ext["id"], "on": True})
        sv.page("site"); time.sleep(1)

        if "late" in ids:
            id = ids["late"]
            sv.cmd({"do": "ext-press", "id": id})
            s = watch(id, 7.5)
            print("late:", s)
            t.ok("late: never a narrow strip first (no width under 100 once shown)",
                 all(x[1] == 0 or x[1] >= 100 for x in s), [x[1] for x in s])
            a = at(s, 2.8); t.ok("late: 380 wide and 10 rows tall at 2.8 s", a and near(a[1], 380) and near(a[2], 300), a)
            b = at(s, 4.8); t.ok("late: shorter with 3 rows at 4.8 s", b and near(b[1], 380) and near(b[2], 90), b)
            c = at(s, 7.4); t.ok("late: taller again with 12 rows at 7.4 s", c and near(c[1], 380) and near(c[2], 360), c)
            sv.cmd({"do": "ext-press", "id": id}); time.sleep(0.8)
            # Opened again: the popover stands at its last size from the start.
            sv.cmd({"do": "ext-press", "id": id})
            r = popup(id, "1") or {}
            t.ok("late: opened again, it starts at its last size", near(((r.get("popover") or {}).get("size") or [0])[0], 380), r.get("popover"))
            sv.cmd({"do": "ext-press", "id": id}); time.sleep(0.8)

        if "hang" in ids:
            id = ids["hang"]
            sv.cmd({"do": "ext-press", "id": id})
            s = watch(id, 3.5)
            print("hang:", s)
            a = at(s, 1.0)
            t.ok("hang: the list hanging under the body counts (300 × 420) within a second", a and near(a[1], 300) and near(a[2], 420), a)
            sv.cmd({"do": "ext-press", "id": id}); time.sleep(0.8)

        if "huge" in ids:
            id = ids["huge"]
            sv.cmd({"do": "ext-press", "id": id})
            s = watch(id, 3.0)
            print("huge:", s)
            a = s[-1] if s else None
            t.ok("huge: held to 800 × 600", a and a[1] <= 800 and a[2] <= 600 and a[1] >= 780 and a[2] >= 580, a)
            sv.cmd({"do": "ext-press", "id": id}); time.sleep(0.8)

        # Relaunched: the popover stands at the last size from the start,
        # and is never shown as the 25-point square while the page builds.
        if "late" in ids:
            id = ids["late"]
            sv.quit(); time.sleep(1)
            sv.launch()
            loaded("Follow late")
            sv.page("site"); time.sleep(1)
            sv.cmd({"do": "ext-press", "id": id})
            r = popup(id, "1") or {}
            t.ok("relaunched: the popover starts at the last size", near(((r.get("popover") or {}).get("size") or [0])[0], 380), r.get("popover"))
            s = watch(id, 2.0)
            t.ok("relaunched: never shown at 25 × 25", all(x[1] == 0 or x[1] >= 100 for x in s), s)
            sv.cmd({"do": "ext-press", "id": id}); time.sleep(0.8)
    finally:
        sv.finish()
        for kind in ("WebKit", "Caches", "HTTPStorages"):
            shutil.rmtree(Path.home() / "Library" / kind / BUNDLE, ignore_errors=True)
        shutil.rmtree(work, ignore_errors=True)
    return t


if __name__ == "__main__":
    result = main()
    result.done()
    sys.exit(1 if result.failed else 0)
