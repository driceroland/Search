#!/usr/bin/env python3
"""Per-extension private consent, checked in a hidden, isolated probe.

Build first (`./build.sh`), then `python3 Tests/private_extensions.py`.
Content scripts, blocking rules, native WebKit APIs and Search's shims must
all respect the same consent, including IDs cached before revocation.
"""
import json
import subprocess
import sys
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# Its own world, apart from the split suite's in this checkout (see use()):
# installed extensions and their own consent defaults.
sv.use("private-extensions")

# The smallest extension that leaves two marks: a content script, run before
# the page's own, that writes an attribute on <html>; and a rule that blocks
# the page's own script, which would write another.
MANIFEST = {
    "manifest_version": 3, "name": "Marker", "version": "1.0", "description": "Leaves a mark on every page.",
    "permissions": ["declarativeNetRequest", "tabs", "scripting", "search", "downloads"], "host_permissions": ["http://*/*"],
    "content_scripts": [{"matches": ["http://*/*"], "js": ["mark.js"], "run_at": "document_start"}],
    "declarative_net_request": {"rule_resources": [{"id": "block", "enabled": True, "path": "rules.json"}]},
}
# One that says it must never run in private ("incognito": "not_allowed"):
# kept out of private tabs whatever the switch says, as Chrome keeps it.
REFUSER = {
    "manifest_version": 3, "name": "Refuser", "version": "1.0", "description": "Never in private.",
    "incognito": "not_allowed",
    "permissions": ["tabs", "scripting"], "host_permissions": ["http://*/*"],
    "content_scripts": [{"matches": ["http://*/*"], "js": ["refuse.js"], "run_at": "document_start"}],
}
REFUSED = "document.documentElement.getAttribute('data-refused')"
RULES = [{"id": 1, "priority": 1, "action": {"type": "block"}, "condition": {"urlFilter": "blocked.js", "resourceTypes": ["script"]}}]
REQUESTS = []


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        REQUESTS.append((self.path, self.headers.get("Cookie", "")))
        if self.path == "/blocked.js":
            kind, body = "text/javascript", b"document.documentElement.setAttribute('data-script', 'ran')"
        elif self.path.startswith("/download-"):
            kind, body = "application/octet-stream", b"private consent test\n"
        else:
            kind = "text/html"
            body = f"<!doctype html><title>{self.path.strip('/')}</title><script src='/blocked.js'></script><p>{self.path}".encode()
        self.send_response(200); self.send_header("Content-Type", kind); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H); threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"
MARKS = "[document.title, document.documentElement.getAttribute('data-marked'), document.documentElement.getAttribute('data-script')]"


# From an extension page, call WebKit's original prototype methods as well
# as the public methods patched by Search. A shim must not hide a native leak.
BOOT = """window.nativeAPI = (space, method, args) => {
  for (let p = Object.getPrototypeOf(chrome[space]); p; p = Object.getPrototypeOf(p)) {
    const d = Object.getOwnPropertyDescriptor(p, method);
    if (d && typeof d.value === 'function') return d.value.apply(chrome[space], args);
  }
  throw new Error('Missing native API: ' + space + '.' + method);
};
window.native = async (api, args) => {
  const r = await chrome.runtime.sendNativeMessage('search', {api, args});
  if (r && r.error) throw new Error(r.error);
  return r && r.value;
};
window.__events = [];
for (const name of ['onCreated', 'onUpdated', 'onActivated', 'onRemoved', 'onMoved']) {
  chrome.tabs[name].addListener((...args) => window.__events.push({name, args}));
}
0"""
LOOK = """const out = [];
  for (const t of await chrome.tabs.query({})) {
    out.push(t.url || "");
    try { const r = await chrome.scripting.executeScript({ target: { tabId: t.id }, func: () => location.href }); out.push("script:" + r[0].result); } catch (e) {}
  }
  return out;"""


def poll(read, ready, seconds=10):
    end = time.monotonic() + seconds
    while True:
        got = read()
        if ready(got): return got
        if time.monotonic() >= end: raise RuntimeError(f"timed out waiting: {got}")
        time.sleep(0.1)


def result(page, body):
    sv.ev(page, "window.__result = null; (async () => {" + body + "})().then("
          "value => window.__result = {ok: true, value: value ?? null}, "
          "error => window.__result = {ok: false, error: String(error)}); 0")
    return poll(lambda: sv.ev(page, "window.__result"), lambda x: x is not None)


def run(page, body):
    got = result(page, body)
    if not got["ok"]: raise RuntimeError(got["error"])
    return got["value"]


def extension_page(ext):
    page = sv.cmd({"do": "ext-page", "id": ext, "path": "page.html"})["id"]
    sv.cmd({"do": "wait", "id": page, "seconds": 10})
    sv.ev(page, BOOT)
    return page


def seen_by(ext):
    page = extension_page(ext)
    try: return run(page, LOOK)
    finally: sv.cmd({"do": "close", "id": page})


def reaches(seen, path):
    return [s for s in seen if s.endswith(f"/{path}")]


def install(folder, name):
    sv.cmd({"do": "ext-folder", "path": folder, "yes": True})
    return poll(lambda: sv.cmd({"do": "extensions"})["extensions"],
                lambda es: any(e["name"] == name and e["loaded"] for e in es), 20)


def extension(ext, loaded=True):
    return poll(lambda: next(e for e in sv.cmd({"do": "extensions"})["extensions"] if e["id"] == ext),
                lambda e: e["loaded"] == loaded, 20)


def consent(ext, on):
    return sv.cmd({"do": "ext-private", "id": ext, "on": on})["private"]


def queries(page):
    return run(page, "return {native: await nativeAPI('tabs', 'query', [{}]), shim: await chrome.tabs.query({})};")


def by_url(tabs, path):
    return next(t for t in tabs if t.get("url") == f"{BASE}/{path}")


def denied(t, page, label, expression):
    got = result(page, "return await " + expression + ";")
    t.ok(label, not got["ok"], got)


def no_private(value, ids, paths, key=None):
    if isinstance(value, dict):
        if value.get("name") in ("onUpdated", "onRemoved", "onMoved") and value["args"][0] in ids: return False
        return all(no_private(v, ids, paths, k) for k, v in value.items())
    if isinstance(value, list): return all(no_private(v, ids, paths, key) for v in value)
    if isinstance(value, int): return key not in ("id", "tabId", "previousTabId") or value not in ids
    return not isinstance(value, str) or not any(path in value for path in paths)


def event_ids(events):
    ids = set()
    for event in events:
        if event["name"] in ("onUpdated", "onRemoved", "onMoved"): ids.add(event["args"][0])
        for arg in event["args"]:
            if isinstance(arg, dict): ids.update(arg[k] for k in ("id", "tabId", "previousTabId") if isinstance(arg.get(k), int) and arg[k] >= 0)
    return ids


def marks(id, name, want, tries=10):
    """[title, content script's mark, page script's mark] once the page named
    is there — tried again a few times: WebKit compiles an extension's
    blocking rules after it has loaded, and adds them to the pages' controllers
    a moment later. Once only where nothing is expected, so a page that still
    got the extension right after the switch went off isn't hidden by the next."""
    for _ in range(tries):
        sv.cmd({"do": "wait", "id": id, "seconds": 10})
        got = sv.ev(id, MARKS)
        if got == [name] + want: return got
        time.sleep(0.3); sv.cmd({"do": "go", "id": id, "url": f"{BASE}/{name}"})
    return got


def opened(private, name, want, tries=10):
    tab = sv.cmd({"do": "open", "url": f"{BASE}/{name}", "private": private})
    return tab, marks(tab["id"], name, want, tries)


SCRIPTED = ["yes", None]   # the extension's script ran, the page's own was blocked
BARE = [None, "ran"]       # no extension on the page: no mark, nothing blocked


def main():
    t = sv.T()
    with tempfile.TemporaryDirectory() as root:
        for name, attribute in (("Marker", "marked"), ("Second", "second"), ("Refuser", "refused"), ("Newcomer", "newcomer")):
            folder = Path(root, name); folder.mkdir()
            manifest = MANIFEST if name == "Marker" else dict(REFUSER, name=name)
            if name not in ("Marker", "Refuser"): manifest.pop("incognito")
            Path(folder, "manifest.json").write_text(json.dumps(manifest))
            script = "mark.js" if name == "Marker" else "refuse.js"
            Path(folder, script).write_text(f"document.documentElement.setAttribute('data-{attribute}', 'yes')")
            Path(folder, "rules.json").write_text(json.dumps(RULES))
            Path(folder, "page.html").write_text("<!doctype html><title>page</title>")
        try:
            sv.setup(**{"extensions.private": True})
            for key, value in (("search.engine", "custom"), ("search.custom", f"{BASE}/search-%s")):
                subprocess.run(["defaults", "write", sv.SUITE, key, "-string", value], check=True)
            sv.launch()
            for name in ("Marker", "Second", "Refuser"):
                loaded = install(str(Path(root, name)), name)
                t.ok(f"{name} loads without errors", any(e["name"] == name and not e["errors"] for e in loaded), loaded)
            marker = next(e["id"] for e in loaded if e["name"] == "Marker")
            second = next(e["id"] for e in loaded if e["name"] == "Second")
            refuser = next(e["id"] for e in loaded if e["name"] == "Refuser")
            t.ok("every extension starts denied, ignoring the legacy global true", all(e["private"] is False for e in loaded), loaded)
            plain, got = opened(False, "plain", SCRIPTED)
            t.ok("an ordinary tab: its script runs, its rule blocks", got == ["plain"] + SCRIPTED, got)
            t.ok("the denied second extension and refuser run normally", sv.ev(plain["id"], "[document.documentElement.getAttribute('data-second'), " + REFUSED + "]") == ["yes", "yes"])
            old, got = opened(True, "default-private", BARE, tries=1)
            t.ok("without individual consent a private page has no controller, script or rule", old["shy"] and not old["extensions"] and got == ["default-private"] + BARE, (old, got))
            t.ok("allowing Marker changes only Marker", consent(marker, True) and not extension(second)["private"])
            t.ok("a manifest refusal overrides individual consent", consent(refuser, True) is False and not extension(refuser)["private"])
            sv.cmd({"do": "go", "id": old["id"], "url": f"{BASE}/old-private"})
            t.ok("an unattached private page still needs reopening", marks(old["id"], "old-private", BARE, tries=1) == ["old-private"] + BARE)
            sv.cmd({"do": "close", "id": old["id"]})
            private, got = opened(True, "private", SCRIPTED)
            t.ok("an allowed private page gets its script and blocking rule", private["shy"] and private["extensions"] and got == ["private"] + SCRIPTED, (private, got))
            t.ok("other extensions remain absent from the shared controller", sv.ev(private["id"], "[document.documentElement.getAttribute('data-second'), " + REFUSED + "]") == [None, None])
            ordinary, got = opened(False, "ordinary", SCRIPTED)
            t.ok("the ordinary page after a private page keeps both marks", got == ["ordinary"] + SCRIPTED, got)
            loaded = install(str(Path(root, "Newcomer")), "Newcomer")
            t.ok("installing another extension does not inherit consent", next(e for e in loaded if e["name"] == "Newcomer")["private"] is False)
            sv.cmd({"do": "go", "id": private["id"], "url": f"{BASE}/private"})
            marks(private["id"], "private", SCRIPTED)
            t.ok("a newly installed extension cannot run in an allowed private page", sv.ev(private["id"], "document.documentElement.getAttribute('data-newcomer')") is None)
            seen = seen_by(marker)
            t.ok("the marker's tabs API sees the private tab, and scripts it", len(reaches(seen, "private")) == 2, seen)
            for ext in (second, refuser):
                seen = seen_by(ext)
                t.ok("a denied extension cannot discover or script the private page", not reaches(seen, "private") and len(reaches(seen, "plain")) == 2, seen)
            a, b, r = (extension_page(ext) for ext in (marker, second, refuser))
            regular_ids = {page: {tab["id"] for tab in queries(page)["native"] if tab.get("url") != f"{BASE}/private"} for page in (a, b, r)}
            event_private, got = opened(True, "event-private", SCRIPTED)
            t.ok("the private event fixture carries the allowed extension", event_private["extensions"] and got == ["event-private"] + SCRIPTED, got)
            sv.cmd({"do": "go", "id": event_private["id"], "url": f"{BASE}/event-private-updated"})
            sv.cmd({"do": "wait", "id": event_private["id"], "seconds": 10})
            sv.cmd({"do": "select", "id": event_private["id"]})
            sv.cmd({"do": "select", "id": plain["id"]})
            sv.cmd({"do": "close", "id": event_private["id"]})
            allowed = queries(a)
            cached = by_url(allowed["native"], "private")
            private_id = cached["id"]
            for kind, tabs in allowed.items():
                indexes = [by_url(tabs, name)["index"] for name in ("plain", "private", "ordinary")]
                t.ok(f"allowed {kind} query keeps ordinary-private-ordinary order", indexes == list(range(indexes[0], indexes[0] + 3)), indexes)
            # WebKit calls every tab of a mixed window not private; the shim
            # marks the private ones for an extension let into them.
            t.ok("an allowed query marks only the private tab incognito", [x["incognito"] for x in allowed["shim"] if x["id"] == private_id] == [True] and not any(x["incognito"] for x in allowed["shim"] if x["id"] != private_id), allowed["shim"])
            got = run(a, f"return [await chrome.tabs.get({private_id}), await chrome.windows.getAll({{populate: true}})];")
            t.ok("an allowed get and windows.getAll mark it too", got[0]["incognito"] is True and [x["incognito"] for w in got[1] for x in w["tabs"] if x["id"] == private_id] == [True], got)
            told = lambda e: e["args"][0] if e["name"] == "onCreated" else e["args"][2] if e["name"] == "onUpdated" else None
            events = poll(lambda: sv.ev(a, "window.__events"), lambda es: any((told(e) or {}).get("url") == f"{BASE}/event-private-updated" for e in es))
            event_id = next(told(e)["id"] for e in events if (told(e) or {}).get("url") == f"{BASE}/event-private-updated")
            tabs = [told(e) for e in events if told(e)]
            t.ok("allowed onCreated and onUpdated mark the private tab, and only it", any(x["id"] == event_id for x in tabs) and all(x["incognito"] is (x["id"] == event_id) for x in tabs), tabs)
            t.ok("the browser tells an allowed extension of its private tabs", run(a, "return await native('tabs.private', []);") is True)
            for page in (b, r):
                for kind, tabs in queries(page).items():
                    regular = [by_url(tabs, name) for name in ("plain", "ordinary")]
                    t.ok(f"denied {kind} query omits private IDs, URLs and titles", no_private(tabs, set(), [f"{BASE}/private"]) and len(tabs) == len(allowed[kind]) - 1, tabs)
                    t.ok(f"denied {kind} indexes skip the private page", regular[1]["index"] == regular[0]["index"] + 1, regular)
                windows = run(page, "return [await nativeAPI('windows', 'getAll', [{populate: true}]), await chrome.windows.getAll({populate: true})];")
                t.ok("native and shim window queries also omit private tabs", no_private(windows, set(), [f"{BASE}/private"]) and all(sum(len(w["tabs"]) for w in group) == len(tabs) for group in windows), windows)
            target = by_url(queries(b)["shim"], "ordinary")
            got = run(b, f"return await native('tabs.describe', [[{{i: {target['index']}}}]]);")
            t.ok("native shim lookup uses the caller's filtered index", got[0]["url"] == f"{BASE}/ordinary", got)
            for page in (b, r):
                count = len(queries(page)["native"])
                got = run(page, f"return [await native('tabs.private', []), await native('tabs.private', [[...Array({count + 1}).keys()].map((i) => ({{i}}))])];")
                t.ok("a denied extension learns of no private tab, at any place", got == [False, [False] * (count + 1)], got)
            run(b, f"await chrome.tabs.highlight({{tabs: {target['index']}}});")
            t.ok("highlight at the filtered index activates the ordinary page", next(x for x in sv.cmd({"do": "tabs"})["tabs"] if x["active"])["id"] == ordinary["id"])
            sv.cmd({"do": "select", "id": plain["id"]})
            sv.cmd({"do": "select", "id": private["id"]})
            got = run(b, "return await nativeAPI('windows', 'getCurrent', [{populate: true}]);")
            t.ok("an active private page leaves an accessible regular fallback", any(x.get("active") and x.get("url") == f"{BASE}/plain" for x in got["tabs"]), got)
            row = [tab["id"] for tab in sv.cmd({"do": "tabs"})["tabs"]]
            before = {page: len(sv.ev(page, "window.__events")) for page in (a, b, r)}
            old_index = row.index(private["id"])
            sv.cmd({"do": "place", "id": private["id"], "to": old_index - 1})
            moved = poll(lambda: sv.ev(a, "window.__events")[before[a]:], lambda es: any(e["name"] == "onMoved" and e["args"][0] == private_id for e in es))
            movement = next(e["args"][1] for e in moved if e["name"] == "onMoved" and e["args"][0] == private_id)
            t.ok("an allowed move event has the old and new private indexes", movement["fromIndex"] == cached["index"] and movement["toIndex"] == cached["index"] - 1, movement)
            sv.cmd({"do": "place", "id": private["id"], "to": old_index})
            poll(lambda: sv.ev(a, "window.__events")[before[a]:], lambda es: sum(e["name"] == "onMoved" and e["args"][0] == private_id for e in es) >= 2)
            t.ok("the private move fixture restores the original order", [tab["id"] for tab in sv.cmd({"do": "tabs"})["tabs"]] == row)
            for page in (b, r):
                events = sv.ev(page, "window.__events")[before[page]:]
                t.ok("moving a denied private page emits no move events", not any(e["name"] == "onMoved" for e in events), events)

            # Keep the native ID acquired with consent, then try every mutator
            # after revocation. Query filtering alone cannot pass these checks.
            sv.ev(private["id"], "document.cookie = 'session=private-secret; Path=/'; 0")
            t.ok("revocation updates the running extension", consent(marker, False) is False)
            # Shut out, it is told the private tabs it knew have closed, so the
            # IDs it kept stop working, and it hears nothing of them after.
            poll(lambda: sv.ev(a, "window.__events"), lambda es: any(e["name"] == "onRemoved" and e["args"][0] == private_id for e in es))
            t.ok("revoked, the browser tells of no private tab", run(a, "return await native('tabs.private', []);") is False)
            sv.ev(a, "window.__events = []; 0")
            for kind, tabs in queries(a).items():
                t.ok(f"revoked {kind} query drops the cached private ID", no_private(tabs, {private_id}, [f"{BASE}/private"]), tabs)
            calls = [
                ("get", f"nativeAPI('tabs', 'get', [{private_id}])"),
                ("public get", f"chrome.tabs.get({private_id})"),
                ("update URL", f"nativeAPI('tabs', 'update', [{private_id}, {{url: '{BASE}/forbidden-change'}}])"),
                ("activate", f"nativeAPI('tabs', 'update', [{private_id}, {{active: true}}])"),
                ("pin", f"nativeAPI('tabs', 'update', [{private_id}, {{pinned: true}}])"),
                ("reload", f"nativeAPI('tabs', 'reload', [{private_id}])"),
                ("back", f"nativeAPI('tabs', 'goBack', [{private_id}])"),
                ("forward", f"nativeAPI('tabs', 'goForward', [{private_id}])"),
                ("read zoom", f"nativeAPI('tabs', 'getZoom', [{private_id}])"),
                ("set zoom", f"nativeAPI('tabs', 'setZoom', [{private_id}, 1.5])"),
                ("public move", f"chrome.tabs.move({private_id}, {{index: 0}})"),
                ("public discard", f"chrome.tabs.discard({private_id})"),
                ("execute script", f"chrome.scripting.executeScript({{target: {{tabId: {private_id}}}, func: () => location.href}})"),
                ("remove", f"nativeAPI('tabs', 'remove', [{private_id}])"),
            ]
            for label, expression in calls: denied(t, a, f"cached private ID rejects {label}", expression)
            denied(t, a, "a mixed window cannot be closed around denied private tabs", f"nativeAPI('windows', 'remove', [{cached['windowId']}])")
            denied(t, a, "direct native search cannot navigate the denied active private page", "native('search.query', [{text: 'denied', disposition: 'CURRENT_TAB'}])")
            # With the private tab in front, a download goes through another
            # of your tabs, never a private one (ExtensionShims.downloadPage).
            run(a, f"await native('downloads.download', [{{url: '{BASE}/download-private-front', filename: 'private-front.txt'}}]);")
            got = poll(lambda: [cookie for path, cookie in REQUESTS if path == "/download-private-front"], lambda cookies: cookies)
            t.ok("a download with the private tab in front never carries its cookies", all("private-secret" not in cookie for cookie in got), got)
            t.ok("denied search makes no HTTP request", not any(path == "/search-denied" for path, _ in REQUESTS), REQUESTS)
            t.ok("cached-ID mutations leave the private address intact", sv.ev(private["id"], "location.href") == f"{BASE}/private")

            # Normal pages still support the same APIs, including native
            # search/download with their own cookies instead of private ones.
            regular_id = by_url(queries(a)["native"], "plain")["id"]
            got = result(a, f"""
                await nativeAPI('tabs', 'get', [{regular_id}]);
                await nativeAPI('tabs', 'update', [{regular_id}, {{url: '{BASE}/normal-update', active: true, pinned: true}}]);
                await nativeAPI('tabs', 'update', [{regular_id}, {{pinned: false}}]);
                await nativeAPI('tabs', 'setZoom', [{regular_id}, 1.2]);
                const zoom = await nativeAPI('tabs', 'getZoom', [{regular_id}]);
                await nativeAPI('tabs', 'setZoom', [{regular_id}, 1]);
                await nativeAPI('tabs', 'reload', [{regular_id}]);
                await nativeAPI('tabs', 'goBack', [{regular_id}]);
                await nativeAPI('tabs', 'goForward', [{regular_id}]);
                return zoom;
            """)
            t.ok("normal native mutations still work", got["ok"] and abs(got["value"] - 1.2) < 0.01, got)
            # WebKit exposes an unimplemented public tabs.move stub on some
            # releases. Exercise Search's existing handlers directly as well.
            target = by_url(queries(a)["native"], "ordinary")
            run(a, f"await native('tabs.move', [{{i: {target['index']}}}, 0]);")
            moved = by_url(queries(a)["native"], "ordinary")
            t.ok("the native move shim moves the regular tab at its filtered index", moved["id"] == target["id"] and moved["index"] == 0, moved)
            got = result(a, "await native('tabs.discard', [{i: 0}]);")
            t.ok("the native discard shim accepts the accessible regular tab", got["ok"], got)
            for api in ("tabs.move", "tabs.discard"):
                denied(t, a, f"{api} rejects an out-of-range filtered index", f"native('{api}', [{{i: 100000}}, 0])")
            sv.cmd({"do": "go", "id": plain["id"], "url": f"{BASE}/normal-session"})
            sv.cmd({"do": "wait", "id": plain["id"], "seconds": 10})
            sv.ev(plain["id"], "document.cookie = 'session=regular; Path=/'; 0")
            sv.cmd({"do": "select", "id": plain["id"]})
            run(a, "await native('search.query', [{text: 'normal', disposition: 'CURRENT_TAB'}]);")
            sv.cmd({"do": "wait", "id": plain["id"], "seconds": 10})
            run(a, f"await native('downloads.download', [{{url: '{BASE}/download-normal', filename: 'normal.txt'}}]);")
            received = poll(lambda: [x for x in REQUESTS if x[0] in ("/search-normal", "/download-normal")], lambda xs: len({x[0] for x in xs}) == 2)
            t.ok("normal search and download use only the regular session cookie", all("session=regular" in cookie and "private-secret" not in cookie for _, cookie in received), received)

            sv.cmd({"do": "go", "id": private["id"], "url": f"{BASE}/revoked-private"})
            got = marks(private["id"], "revoked-private", BARE, tries=1)
            t.ok("revocation removes both scripts and rules on the next private navigation", got == ["revoked-private"] + BARE, got)
            sv.ev(private["id"], "document.title = 'revoked-private-title'; 0")
            sv.cmd({"do": "select", "id": private["id"]})
            sv.cmd({"do": "select", "id": ordinary["id"]})
            sv.cmd({"do": "close", "id": private["id"]})
            fresh, got = opened(True, "fresh-private", BARE, tries=1)
            t.ok("after revocation a new private page carries no extensions", not fresh["extensions"] and got == ["fresh-private"] + BARE, (fresh, got))
            normal, got = opened(False, "normal-event", SCRIPTED)
            t.ok("ordinary pages keep content scripts and blocking rules", got == ["normal-event"] + SCRIPTED, got)
            normal_ids = {}
            for page in (a, b, r):
                tabs = queries(page)["native"]
                regular_ids[page].update(tab["id"] for tab in tabs)
                normal_ids[page] = by_url(tabs, "normal-event")["id"]
            sv.cmd({"do": "select", "id": normal["id"]})
            run(a, f"await nativeAPI('tabs', 'remove', [{normal_ids[a]}]);")
            for page in (a, b, r):
                events = poll(lambda: sv.ev(page, "window.__events"), lambda es: any(e["name"] == "onRemoved" and e["args"][0] == normal_ids[page] for e in es))
                t.ok("normal tab create/update/activate/remove events still arrive", {"onCreated", "onUpdated", "onActivated", "onRemoved"}.issubset({e["name"] for e in events}), events)
                t.ok("denied private events expose no ID, URL or title", event_ids(events) <= regular_ids[page] and no_private(events, set(), [f"{BASE}/private", "event-private", "revoked-private", "fresh-private"]), events)
            # A tab opened in front: its onCreated waits for the browser's
            # answer, and its onActivated has to wait behind it.
            sv.ev(a, "window.__events = []; 0")
            front = run(a, f"return (await chrome.tabs.create({{url: '{BASE}/in-front', active: true}})).id;")
            events = poll(lambda: sv.ev(a, "window.__events"), lambda es: any(e["name"] == "onActivated" and e["args"][0]["tabId"] == front for e in es))
            heard = [e["name"] for e in events if (told(e) or {}).get("id") == front or (e["name"] == "onActivated" and e["args"][0]["tabId"] == front)]
            t.ok("a new tab's onCreated still comes before its onActivated", "onCreated" in heard and heard.index("onCreated") < heard.index("onActivated"), heard)
            run(a, f"await chrome.tabs.remove({front});")

            consent(marker, True)
            tab, got = opened(True, "back", SCRIPTED)
            t.ok("granting again while running restores scripts and blocking rules", got == ["back"] + SCRIPTED, got)
            t.ok("the refuser is still excluded after another grant", sv.ev(tab["id"], REFUSED) is None)
            for page in (a, b, r): sv.cmd({"do": "close", "id": page})
            Path(root, "Marker", "manifest.json").write_text(json.dumps(dict(MANIFEST, version="1.1")))
            sv.cmd({"do": "ext-reload", "id": marker})
            reloaded = poll(lambda: extension(marker), lambda e: e["version"] == "1.1")
            t.ok("consent survives extension reload", reloaded["private"] is True)
            sv.cmd({"do": "ext-enable", "id": marker, "on": False}); extension(marker, loaded=False)
            sv.cmd({"do": "ext-enable", "id": marker, "on": True})
            t.ok("consent survives disable and enable", extension(marker)["private"] is True)
            sv.quit(); sv.launch()
            t.ok("consent survives restart without granting the other extensions", extension(marker)["private"] is True and not extension(second)["private"] and not extension(refuser)["private"])
            tab, got = opened(True, "restart-private", SCRIPTED)
            t.ok("persisted consent restores both WebKit gates at launch", got == ["restart-private"] + SCRIPTED, got)
            t.ok("the manifest refusal still holds at launch", sv.ev(tab["id"], REFUSED) is None)
            sv.cmd({"do": "ext-remove", "id": marker})
            poll(lambda: sv.cmd({"do": "extensions"})["extensions"], lambda es: not any(e["id"] == marker for e in es))
            removed = poll(lambda: subprocess.run(["defaults", "read", sv.SUITE, f"extensions.private.{marker}"], capture_output=True), lambda p: p.returncode != 0)
            t.ok("removal clears the same-ID consent key", removed.returncode != 0)
            tab, got = opened(True, "removed-private", BARE, tries=1)
            t.ok("removal leaves no private controller or inherited grant", not tab["extensions"] and got == ["removed-private"] + BARE, (tab, got))
        finally:
            t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
