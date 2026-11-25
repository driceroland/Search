#!/usr/bin/env python3
"""chrome.declarativeContent's RequestContentScript injects an extension's
scripts where its rules say, and only there (idea 1198: Everhour on Linear),
in a hidden probe.

A test extension asks for an optional site (localhost) with
permissions.request, then adds onPageChanged rules whose action is
RequestContentScript, as Everhour does once it is given linear.app:

- a: urlPrefix http://localhost:PORT/dc-, css ["body"] -> content.js + content.css
  (Everhour's own shape)
- b: 127.0.0.1 -> content.js (a site it was never given: never runs)
- c: localhost, path /late, css ["#late"] -> content.js, once #late shows up
- d: localhost, path /frames -> all_frames + match_about_blank
- e: localhost, path /noframes -> top frame only

Then: getRules gives them back, removeRules takes one away, and after a
relaunch the optional site is still granted and the rules still inject.

Build first (`./build.sh debug`), then, one probe at a time,
`lockf -t 900 /private/tmp/claude-501/search-probe.lock.N python3 Tests/extension_declarative_content.py`.
Hidden, in a world of its own (split_view.py's harness); the app copy, its
WebKit folders and the world are removed afterwards. The two sites are this
test's page server under two names, 127.0.0.1 and localhost.
"""
import json
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("ext-dc")
BUNDLE = "com.officecommun.search.declarativecontent"
work = Path(tempfile.mkdtemp(prefix="search-dc-"))

FRAMES = "<iframe src='/child'></iframe><iframe src='about:blank'></iframe>"


class Pages(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        if path.startswith("/late"):
            body = "<p>late<script>setTimeout(() => { const d = document.createElement('div'); d.id = 'late'; document.body.append(d); }, 1500)</script>"
        elif path.startswith("/frames") or path.startswith("/noframes"):
            body = "<p>frames" + FRAMES
        else:
            body = f"<p>{path}"
        data = f"<!doctype html><title>{path}</title><body>{body}</body>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a): pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
threading.Thread(target=srv.serve_forever, daemon=True).start()
PORT = srv.server_port
A = f"http://127.0.0.1:{PORT}"
B = f"http://localhost:{PORT}"

# Wrapped, as bundled scripts are: a second run must count, not throw.
CONTENT = """
(() => {
  if (window === window.top) {
    const root = document.documentElement;
    root.setAttribute('data-dc', String(Number(root.getAttribute('data-dc') || 0) + 1));
    return;
  }
  const kind = location.href.startsWith('about:') ? 'blank' : 'child';
  try {
    const top = window.top.document.documentElement;
    top.setAttribute('data-dc-' + kind, String(Number(top.getAttribute('data-dc-' + kind) || 0) + 1));
  } catch (e) {}
})();
"""

WORKER = """
const dc = chrome.declarativeContent;
const local = (pathPrefix, more = {}) => new dc.PageStateMatcher({ pageUrl: { hostEquals: 'localhost', pathPrefix }, ...more });
const rules = [
  { id: 'a', conditions: [new dc.PageStateMatcher({ pageUrl: { urlPrefix: 'http://localhost:__PORT__/dc-' }, css: ['body'] })], actions: [new dc.RequestContentScript({ js: ['content.js'], css: ['content.css'] })] },
  { id: 'b', conditions: [new dc.PageStateMatcher({ pageUrl: { hostEquals: '127.0.0.1' } })], actions: [new dc.RequestContentScript({ js: ['content.js'] })] },
  { id: 'c', conditions: [local('/late', { css: ['#late'] })], actions: [new dc.RequestContentScript({ js: ['content.js'] })] },
  { id: 'd', conditions: [local('/frames')], actions: [new dc.RequestContentScript({ js: ['content.js'], allFrames: true, matchAboutBlank: true })] },
  { id: 'e', conditions: [local('/noframes')], actions: [new dc.RequestContentScript({ js: ['content.js'] })] },
];
const getRules = () => new Promise((r) => dc.onPageChanged.getRules((l) => r((l || []).map((x) => x.id).sort())));
const tell = async (said) => {
  const held = await chrome.permissions.contains({ origins: ['*://localhost/*'] });
  chrome.action.setTitle({ title: JSON.stringify({ said, held, rules: await getRules() }) });
};
tell('start');
const steps = [
  async () => {
    const given = await chrome.permissions.request({ origins: ['*://localhost/*'] });
    await new Promise((r) => dc.onPageChanged.removeRules(undefined, r));
    const added = await new Promise((r) => dc.onPageChanged.addRules(rules, r));
    return [given, (added || []).length];
  },
  () => new Promise((r) => dc.onPageChanged.removeRules(['a'], () => r('removed'))),
  () => chrome.permissions.remove({ origins: ['*://localhost/*'] }).then((v) => 'gave back ' + v),
];

let next = 0;
chrome.action.onClicked.addListener(() => {
  const step = steps[next++];
  if (!step) return;
  Promise.resolve().then(step).then((v) => v, (e) => 'error: ' + (e && e.message)).then(tell);
});
"""

EXT = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "Rules", "version": "1.0",
        "permissions": ["declarativeContent"],
        "optional_host_permissions": ["*://localhost/*"],
        "action": {"default_title": "Rules"},
        "background": {"service_worker": "worker.js"},
    }),
    "content.js": CONTENT,
    "content.css": "html { --dc: 1; }",
    "worker.js": WORKER.replace("__PORT__", str(PORT)),
}


def probe_copy():
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def ev(page, js):
    return sv.cmd({"do": "eval", "id": page, "js": js}).get("value")


def attr(page, name, within=3.0, settle=0.0):
    """The page's data-NAME once it shows (or '' after `within`); `settle`
    waits that long more and reads again, so a second run is counted."""
    end = time.time() + within
    js = f"document.documentElement.getAttribute('data-{name}') || ''"
    value = ev(page, js)
    while not value and time.time() < end:
        time.sleep(0.25)
        value = ev(page, js)
    if settle:
        time.sleep(settle)
        value = ev(page, js)
    return value


def opened(url):
    page = sv.sp("open", url=url)["resultID"]
    time.sleep(1.0)
    return page


def ext(id):
    return next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["id"] == id), None)


def title(id, want=None, within=8.0):
    end = time.time() + within
    while True:
        x = ext(id)
        text = x["action"] if x else ""
        said = json.loads(text) if text.startswith("{") else text
        if want is None or (isinstance(said, dict) and want(said)) or time.time() > end:
            return said
        time.sleep(0.25)


def main():
    t = sv.T()
    folder = work / "rules"
    folder.mkdir()
    for file, body in EXT.items(): (folder / file).write_text(body)
    sv.APP = probe_copy()
    report = []
    try:
        sv.setup()
        sv.launch()
        sv.cmd({"do": "ext-answer", "answer": "yes"})
        sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
        id = None
        for _ in range(60):
            x = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == "Rules" and x["loaded"]), None)
            if x: id = x["id"]; break
            time.sleep(0.25)
        t.ok("the test extension loads", id is not None)
        if not id: return t, report
        start = title(id, lambda s: s.get("said") == "start")
        report.append(("worker at start", start))

        before = opened(f"{B}/dc-before")
        t.ok("before it is given the site, nothing runs", attr(before, "dc", within=2) == "")

        sv.cmd({"do": "ext-press", "id": id})
        said = title(id, lambda s: isinstance(s.get("said"), list))
        report.append(("after the request and addRules", said))
        t.ok("permissions.request gives the optional site", isinstance(said, dict) and said.get("held") is True, said)
        t.ok("addRules takes all five and getRules gives them back",
             isinstance(said, dict) and said.get("said") == [True, 5] and said.get("rules") == ["a", "b", "c", "d", "e"], said)
        report.append(("granted", sv.cmd({"do": "ext-sites", "id": id}).get("granted")))

        a = opened(f"{B}/dc-one")
        t.ok("a: a matching page gets the script, once", attr(a, "dc", settle=1.0) == "1", attr(a, "dc"))
        t.ok("a: and its stylesheet", ev(a, "getComputedStyle(document.documentElement).getPropertyValue('--dc').trim()") == "1")
        other = opened(f"{B}/other")
        t.ok("a page on the site that no rule matches gets nothing", attr(other, "dc", within=2) == "")
        b = opened(f"{A}/dc-one")
        t.ok("b: a site it wasn't given gets nothing, though a rule names it", attr(b, "dc", within=2) == "")

        late = sv.sp("open", url=f"{B}/late")["resultID"]
        time.sleep(0.6)
        early = attr(late, "dc", within=0)
        t.ok("c: nothing before the css condition holds", early == "", early)
        t.ok("c: the script once #late shows up", attr(late, "dc", within=4, settle=1.0) == "1", attr(late, "dc"))

        frames = opened(f"{B}/frames")
        got = {k: attr(frames, k, within=3, settle=0.5) for k in ("dc", "dc-child", "dc-blank")}
        report.append(("d: all frames + about:blank", got))
        t.ok("d: all_frames: top and frame, once each", got["dc"] == "1" and got["dc-child"] == "1", got)
        # WebKit refuses scripting.executeScript in about:blank frames ("does
        # not have access to this frame"), so match_about_blank can't reach
        # them yet. Reported, not failed: a WebKit that lets them in shows
        # up here as "1".
        report.append(("d: about:blank frame (WebKit refuses it for now)", got["dc-blank"] or "not reached"))
        t.ok("d: never more than once in the about:blank frame", got["dc-blank"] in ("", "1"), got)
        noframes = opened(f"{B}/noframes")
        got = {k: attr(noframes, k, within=2, settle=0.5) for k in ("dc", "dc-child", "dc-blank")}
        report.append(("e: top frame only", got))
        t.ok("e: top frame only", got == {"dc": "1", "dc-child": "", "dc-blank": ""}, got)

        sv.cmd({"do": "ext-press", "id": id})
        said = title(id, lambda s: s.get("said") == "removed")
        t.ok("removeRules(['a']) leaves the other four", isinstance(said, dict) and said.get("rules") == ["b", "c", "d", "e"], said)
        gone = opened(f"{B}/dc-two")
        t.ok("a removed: the next matching page gets nothing", attr(gone, "dc", within=2.5) == "")

        # Relaunched: the site it was given and its rules are still there.
        sv.quit()
        time.sleep(1)
        sv.launch()
        for _ in range(60):
            x = ext(id)
            if x and x["loaded"]: break
            time.sleep(0.25)
        report.append(("granted after relaunch", sv.cmd({"do": "ext-sites", "id": id}).get("granted")))
        frames = opened(f"{B}/frames-again")
        t.ok("after a relaunch, a rule kept still injects", attr(frames, "dc", within=6, settle=1.0) == "1", attr(frames, "dc"))
        said = title(id, lambda s: s.get("said") == "start" and s.get("rules"))
        report.append(("worker after relaunch", said))
        t.ok("after a relaunch, the optional site is still given", isinstance(said, dict) and said.get("held") is True, said)
        t.ok("after a relaunch, getRules gives the rules kept", isinstance(said, dict) and said.get("rules") == ["b", "c", "d", "e"], said)
        gone = opened(f"{B}/dc-three")
        t.ok("after a relaunch, the removed rule stays removed", attr(gone, "dc", within=2.5) == "")

        # Given back (permissions.remove), and relaunched: not given again.
        # The worker started over, so its steps did too: the third press is
        # the one that gives the site back.
        for _ in range(3):
            sv.cmd({"do": "ext-press", "id": id})
            time.sleep(1.0)
        said = title(id, lambda s: str(s.get("said", "")).startswith("gave back"))
        t.ok("permissions.remove gives the site back", isinstance(said, dict) and said.get("held") is False, said)
        sv.quit()
        time.sleep(1)
        sv.launch()
        said = title(id, lambda s: s.get("said") == "start" and s.get("rules"), within=15)
        report.append(("worker after giving it back and a relaunch", said))
        t.ok("given back, then relaunched: the site stays given back", isinstance(said, dict) and said.get("held") is False, said)
        gone = opened(f"{B}/frames-gone")
        t.ok("given back: its rules inject nothing", attr(gone, "dc", within=2.5) == "")
        report.append(("errors", (ext(id) or {}).get("reported")))
    finally:
        sv.finish()
        for kind in ("WebKit", "Caches", "HTTPStorages"):
            shutil.rmtree(Path.home() / "Library" / kind / BUNDLE, ignore_errors=True)
        shutil.rmtree(work, ignore_errors=True)
        srv.shutdown()
    return t, report


if __name__ == "__main__":
    t, report = main()
    print("\nwhat it saw:")
    for name, value in report:
        print(f"  {name}: {value}")
    t.done()
    sys.exit(1 if t.failed else 0)
