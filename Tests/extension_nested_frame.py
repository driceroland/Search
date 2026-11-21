#!/usr/bin/env python3
"""An extension's page in a frame inside an empty frame, as Similarweb's
panel is built — in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/extension_nested_frame.py`.
It runs a copy of build/Search.app under a bundle id of its own, hidden, in
a world of its own with split_view.py's harness; the copy, its WebKit
folders and the world are removed afterwards.

Similarweb's button slides a panel in from the side of the page. Its content
script puts an empty frame in the page (no address: the site's styles can't
reach into it), and when that has loaded, a style and a frame inside it with
the panel's page, panel/panel.html, one of its web_accessible_resources.
Then it waits for the panel's page to load before sliding the panel in.

WebKit checks web_accessible_resources against the address of the frame
just above the one being loaded. Above the panel's frame that is the empty
frame, about:blank, which no pattern matches: the page was refused, nothing
said, and the button did nothing. Chrome checks the site. The extension
here builds its frames the same way. What is checked:

- its page loads in a frame of the site, as it always did;
- and in a frame inside an empty frame, given its address before it is put
  there (Similarweb), after, or with setAttribute (React);
- the empty frame keeps what the extension put in it, and its load is heard
  once: a second would build a second panel;
- a page that isn't among web_accessible_resources is still refused there.
"""
import json
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("extension-nested-frame")
BUNDLE = "com.officecommun.search.nestedframe"
work = Path(tempfile.mkdtemp(prefix="search-nestedframe-"))
NAME = "Nested"

FILES = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": NAME, "version": "1.0",
        "content_scripts": [{"matches": ["<all_urls>"], "js": ["content.js"], "run_at": "document_end"}],
        "web_accessible_resources": [{"resources": ["panel.html", "panel.js"], "matches": ["<all_urls>"]}],
    }),
    "panel.html": "<!doctype html><title>panel</title><p>panel</p><script src='panel.js'></script>",
    "private.html": "<!doctype html><title>private</title><p>private</p><script src='panel.js'></script>",
    "panel.js": "window.top.postMessage({ nested: location.pathname + location.search }, '*');",
    # What it finds goes on the page's root element, where the probe reads it.
    "content.js": """
if (window.top === window) {
  const root = document.documentElement;
  const note = (key, value) => { root.dataset[key] = (root.dataset[key] || "") + value + ";"; };
  window.addEventListener("message", (e) => { if (e.data && e.data.nested) note("shown", e.data.nested); });
  const page = (name) => chrome.runtime.getURL(name);
  const frame = (id) => { const f = document.createElement("iframe"); f.id = id; return f; };
  // In the page itself.
  const direct = frame("direct"); direct.src = page("panel.html?direct"); document.body.appendChild(direct);
  // Similarweb's: an empty frame, and at its load a style and the panel's frame inside.
  const empty = (id, fill) => { const f = frame(id); f.onload = () => { note("loads", id); fill(f.contentDocument); }; document.body.appendChild(f); };
  empty("before", (d) => {
    const style = document.createElement("style"); style.innerText = "body{margin:0}"; d.head.appendChild(style);
    const mark = document.createElement("p"); mark.id = "mark"; mark.kept = "kept"; d.body.appendChild(mark);
    const inner = frame("inner"); inner.src = page("panel.html?before"); inner.onload = () => note("inner", "before");
    d.body.appendChild(inner);
  });
  empty("after", (d) => { const inner = frame("inner"); d.body.appendChild(inner); setTimeout(() => { inner.src = page("panel.html?after"); }, 100); });
  empty("attribute", (d) => { const inner = frame("inner"); inner.setAttribute("src", page("panel.html?attribute")); d.body.appendChild(inner); });
  empty("refused", (d) => { const inner = frame("inner"); inner.src = page("private.html?refused"); d.body.appendChild(inner); });
  setTimeout(() => {
    const d = document.getElementById("before").contentDocument, mark = d.getElementById("mark");
    note("kept", [d.head.querySelectorAll("style").length, d.body.children.length, mark && mark.kept, d.querySelectorAll("iframe").length].join(","));
  }, 2500);
}
""",
}


def probe_copy():
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def noted(page):
    raw = sv.ev(page, "JSON.stringify(Object.assign({}, document.documentElement.dataset))")
    return {k: [x for x in v.split(";") if x] for k, v in json.loads(raw or "{}").items()}


def main():
    t = sv.T()
    folder = work / "ext"
    folder.mkdir()
    for name, body in FILES.items(): (folder / name).write_text(body)
    sv.APP = probe_copy()
    try:
        sv.setup()
        sv.launch()
        sv.cmd({"do": "ext-answer", "answer": "yes"})
        sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
        ext = None
        for _ in range(240):
            ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == NAME and x["loaded"]), None)
            if ext: break
            time.sleep(0.25)
        t.ok("the extension loads", ext is not None)
        if not ext: return t
        page = sv.page("site")
        seen = {}
        for _ in range(40):
            seen = noted(page)
            if seen.get("kept") and len(seen.get("shown", [])) >= 4: break
            time.sleep(0.25)
        time.sleep(1.5)  # anything late: a second load, a refused page let through
        seen = noted(page)
        shown = seen.get("shown", [])
        t.ok("its page loads in a frame of the site", "/panel.html?direct" in shown, shown)
        t.ok("…and in a frame inside an empty frame, as Similarweb's panel", "/panel.html?before" in shown, shown)
        t.ok("…given its address after it was put there", "/panel.html?after" in shown, shown)
        t.ok("…or with setAttribute", "/panel.html?attribute" in shown, shown)
        t.ok("each of them once", sorted(shown) == sorted(set(shown)), shown)
        t.ok("the frame inside hears its load, once", seen.get("inner") == ["before"], seen.get("inner"))
        t.ok("each empty frame's load is heard once", sorted(seen.get("loads", [])) == ["after", "attribute", "before", "refused"], seen.get("loads"))
        t.ok("the empty frame keeps what was put in it", seen.get("kept") == ["1,2,kept,1"], seen.get("kept"))
        t.ok("a page that isn't web accessible is still refused there", not any("private" in x for x in shown), shown)
    finally:
        sv.finish()
        for kind in ("WebKit", "Caches", "HTTPStorages"):
            shutil.rmtree(Path.home() / "Library" / kind / BUNDLE, ignore_errors=True)
        shutil.rmtree(work, ignore_errors=True)
    return t


if __name__ == "__main__":
    t = main()
    t.done()
    sys.exit(1 if t.failed else 0)
