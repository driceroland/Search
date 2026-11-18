#!/usr/bin/env python3
"""Permission changes don't run an extension's content scripts again in the
pages they are already in (idea 705), in a hidden probe.

A change to an extension's grants has WebKit look at its content scripts
again, and some changes have it put all of them back into every open page
they may run in, where they run once more: double UI, double listeners. This
counts how many times a content script ran in pages left open while

- "Ask" (permissions): is given an optional API permission, every website
  (an optional <all_urls>), gives it back (permissions.remove), and is given
  one optional site. Its script is registered at run time for <all_urls>
  (scripting.registerContentScripts), so it runs wherever it has access.
- "Sites" (Runs on): asks for every site, and "Runs on" is narrowed from
  every site to two, to one, and widened to two again.

One case is WebKit's own and can't be helped from outside: when every
website is given or taken back as a whole, a page still allowed gets the
scripts once more (WebKit keeps every-website scripts apart from the
per-site ones and swaps one set for the other) — twice on a site the
manifest names when the extension gives every website back itself.
Everything else must leave open pages alone.

Build first (`./build.sh debug`), then, one probe at a time,
`lockf -t 900 /private/tmp/claude-501/search-probe.lock python3 Tests/extension_permission_rerun.py`.
Hidden, in a world of its own (split_view.py's harness); the app copy, its
WebKit folders and the world are removed afterwards. The two sites are the
page server under two names, 127.0.0.1 and localhost.
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

sv.use("extension-permission-rerun")
BUNDLE = "com.officecommun.search.permissionrerun"
work = Path(tempfile.mkdtemp(prefix="search-rerun-"))
PORT = sv.srv.server_port
A = f"http://127.0.0.1:{PORT}"
B = f"http://localhost:{PORT}"


def counter(key):
    # How many times it ran in this page. Wrapped, as bundled scripts are: a
    # top-level const would make a second run a SyntaxError in the
    # extension's world, which hides the second run instead of showing it.
    return f"""
(() => {{
  const root = document.documentElement;
  root.setAttribute('data-{key}', String(Number(root.getAttribute('data-{key}') || 0) + 1));
}})();
"""


ASK = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "Ask", "version": "1.0",
        "permissions": ["scripting"],
        "host_permissions": ["*://127.0.0.1/*"],
        "optional_host_permissions": ["*://localhost/*", "<all_urls>"],
        "optional_permissions": ["cookies"],
        "action": {"default_title": "Ask"},
        "background": {"service_worker": "worker.js"},
    }),
    "content.js": counter("ask"),
    # Its script, for every website it may reach; each press of its button
    # does the next step.
    "worker.js": """
chrome.scripting.getRegisteredContentScripts().then((had) => had.length ? null :
  chrome.scripting.registerContentScripts([{ id: 'count', matches: ['<all_urls>'], js: ['content.js'], runAt: 'document_end' }]));
const steps = [
  () => chrome.permissions.request({ permissions: ['cookies'] }),
  () => chrome.permissions.request({ origins: ['<all_urls>'] }),
  () => chrome.permissions.remove({ origins: ['<all_urls>'] }),
  () => chrome.permissions.request({ origins: ['*://localhost/*'] }),
];
let next = 0;
const said = [];
// What each step answered, and whether every website is then held as
// permissions.contains sees it, as its button's title.
chrome.action.onClicked.addListener(() => {
  const step = steps[next++];
  if (!step) return;
  Promise.resolve(step()).then((v) => v, (e) => 'error: ' + (e && e.message))
    .then(async (v) => {
      said.push([String(v), await chrome.permissions.contains({ origins: ['<all_urls>'] })]);
      chrome.action.setTitle({ title: JSON.stringify(said) });
    });
});
""",
}

SITES = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "Sites", "version": "1.0",
        "host_permissions": ["<all_urls>"],
        "action": {"default_title": "Sites"},
        "content_scripts": [{"matches": ["<all_urls>"], "js": ["content.js"], "run_at": "document_end"}],
    }),
    "content.js": counter("sites"),
}


def probe_copy():
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def ran(page, key, within=3.0):
    """How many times it ran in the page, once it has had time to; '' when it never did."""
    end = time.time() + within
    js = f"document.documentElement.getAttribute('data-{key}') || ''"
    value = sv.cmd({"do": "eval", "id": page, "js": js}).get("value")
    while not value and time.time() < end:
        time.sleep(0.25)
        value = sv.cmd({"do": "eval", "id": page, "js": js}).get("value")
    return value


def opened(url):
    page = sv.sp("open", url=url)["resultID"]
    time.sleep(1.2)
    return page


def counts(pages, key, within=1.0):
    return {name: ran(page, key, within=within) for name, page in pages.items()}


def installed(folder, name):
    sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
    for _ in range(60):
        ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == name and x["loaded"]), None)
        if ext: return ext["id"]
        time.sleep(0.25)
    return None


def granted(id):
    return sorted(p for p in sv.cmd({"do": "ext-sites", "id": id})["granted"] if "chromiumapp" not in p)


def more(before, after):
    """How many more times it ran in each page."""
    return {k: int(after[k] or 0) - int(before[k] or 0) for k in before}


def main():
    t = sv.T()
    for name, files in (("ask", ASK), ("sites", SITES)):
        folder = work / name
        folder.mkdir()
        for file, body in files.items(): (folder / file).write_text(body)
    sv.APP = probe_copy()
    report = []

    def step(name, pages, key, act, settle=2.0):
        before = counts(pages, key)
        act()
        time.sleep(settle)
        d = more(before, counts(pages, key))
        report.append((name, d))
        return d

    try:
        sv.setup()
        sv.launch()
        sv.cmd({"do": "ext-answer", "answer": "yes"})

        # Ask: permissions.request / permissions.remove.
        ask = installed(work / "ask", "Ask")
        t.ok("Ask loads", ask is not None)
        if not ask: return t, report
        time.sleep(1.5)  # its worker registers its script
        a0, b0 = opened(f"{A}/ask-a0"), opened(f"{B}/ask-b0")
        pages = {"127.0.0.1": a0, "localhost": b0}
        start = counts(pages, "ask", within=3)
        t.ok("Ask runs on its site only", start == {"127.0.0.1": "1", "localhost": ""}, start)
        press = lambda: sv.cmd({"do": "ext-press", "id": ask})

        d = step("Ask: permissions.request cookies", pages, "ask", press)
        t.ok("an optional API permission runs nothing again", d == {"127.0.0.1": 0, "localhost": 0}, d)

        d = step("Ask: permissions.request <all_urls>", pages, "ask", press)
        t.ok("every website given: the page on its site runs at most once more (WebKit's)", d["127.0.0.1"] <= 1, d)
        t.ok("every website given: the open page on the new site gets it, once", d["localhost"] == 1, d)
        b1 = opened(f"{B}/ask-b1")
        t.ok("every website given: the next page gets it once, not twice", ran(b1, "ask") == "1", ran(b1, "ask"))
        pages["localhost (later)"] = b1

        d = step("Ask: permissions.remove <all_urls>", pages, "ask", press)
        held = granted(ask)
        report.append(("  held after giving it back", held))
        t.ok("given back: neither <all_urls> nor *://*/* is held", not {"<all_urls>", "*://*/*"} & set(held), held)
        t.ok("given back: pages on the site it lost aren't run again", d["localhost"] == 0 and d["localhost (later)"] == 0, d)
        # WebKit's twice: taking the every-website grant out of the list has
        # it add the scripts of the site it keeps, and only the rebuild that
        # follows clears the every-website ones it leaves behind.
        t.ok("given back: the page on its site runs at most twice more (WebKit's)", d["127.0.0.1"] <= 2, d)
        b2, a2 = opened(f"{B}/ask-b2"), opened(f"{A}/ask-a2")
        fresh = {"localhost": ran(b2, "ask", within=2.5), "127.0.0.1": ran(a2, "ask")}
        report.append(("  next loads after giving it back", fresh))
        t.ok("given back: the next page on the site it lost goes without", fresh["localhost"] == "", fresh)
        t.ok("given back: the next page on its site gets it once", fresh["127.0.0.1"] == "1", fresh)

        pages = {"127.0.0.1": a0, "127.0.0.1 (later)": a2, "localhost": b2}
        d = step("Ask: permissions.request *://localhost/*", pages, "ask", press)
        t.ok("an optional site: pages it already ran in aren't run again", d["127.0.0.1"] == 0 and d["127.0.0.1 (later)"] == 0, d)
        t.ok("an optional site: the open page there gets it, once", d["localhost"] == 1, d)
        report.append(("  asked", sv.cmd({"do": "ext-answer", "answer": "yes"}).get("asked", [])))
        title = next(x for x in sv.cmd({"do": "extensions"})["extensions"] if x["id"] == ask)["action"]
        said = json.loads(title) if title.startswith("[") else title
        report.append(("  Ask's answers, and contains(<all_urls>) after each", said))
        t.ok("every step was granted as asked, and contains() follows",
             said == [["true", False], ["true", True], ["true", False], ["true", False]], said)

        # Sites: Runs on.
        sites = installed(work / "sites", "Sites")
        t.ok("Sites loads", sites is not None)
        if not sites: return t, report
        pages = {"127.0.0.1": opened(f"{A}/sites-a0"), "localhost": opened(f"{B}/sites-b0")}
        start = counts(pages, "sites", within=3)
        t.ok("Sites runs everywhere", start == {"127.0.0.1": "1", "localhost": "1"}, start)
        runs = lambda **f: (lambda: sv.cmd({"do": "ext-sites", "id": sites, **f}))

        d = step("Sites: all -> 127.0.0.1 + localhost", pages, "sites", runs(mode="some", hosts=["127.0.0.1", "localhost"]))
        t.ok("all to some: pages on kept sites run at most once more (WebKit's)", all(v <= 1 for v in d.values()), d)
        pages = {"127.0.0.1": opened(f"{A}/sites-a1"), "localhost": opened(f"{B}/sites-b1")}
        d = step("Sites: -> 127.0.0.1", pages, "sites", runs(mode="some", hosts=["127.0.0.1"]))
        t.ok("narrowed: the kept site's page isn't run again", d["127.0.0.1"] == 0, d)
        t.ok("narrowed: the lost site's page is left as it was", d["localhost"] == 0, d)
        b = opened(f"{B}/sites-b2")
        t.ok("narrowed: the next page on the lost site goes without", ran(b, "sites", within=2.5) == "", ran(b, "sites"))
        d = step("Sites: -> 127.0.0.1 + localhost", pages, "sites", runs(mode="some", hosts=["127.0.0.1", "localhost"]))
        t.ok("widened: the kept site's page isn't run again", d["127.0.0.1"] == 0, d)
        d = step("Sites: -> all", pages, "sites", runs(mode="all"))
        t.ok("back to all: pages run at most once more (WebKit's)", all(v <= 1 for v in d.values()), d)
        a = opened(f"{A}/sites-a3")
        t.ok("back to all: the next page gets it once, not twice", ran(a, "sites") == "1", ran(a, "sites"))
    finally:
        sv.finish()
        for kind in ("WebKit", "Caches", "HTTPStorages"):
            shutil.rmtree(Path.home() / "Library" / kind / BUNDLE, ignore_errors=True)
        shutil.rmtree(work, ignore_errors=True)
    return t, report


if __name__ == "__main__":
    t, report = main()
    print("\nmore runs per open page, step by step:")
    for name, value in report:
        print(f"  {name}: {value}")
    t.done()
    sys.exit(1 if t.failed else 0)
