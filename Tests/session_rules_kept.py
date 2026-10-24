#!/usr/bin/env python3
"""Session rules kept as dynamic ones ("Session rules, kept" in
ExtensionShims.swift), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/session_rules_kept.py`. A
small extension of its own sets rules that stop requests to a local server,
across four launches of a world of its own (SEARCH_PROBE=session-kept):

    1  a session rule stops what it should; getSessionRules lists it and
       getDynamicRules doesn't, even beside a dynamic rule of the same id;
       one whose regex the shim splits is kept all the same, listed once;
       a redirect whose regexSubstitution says \\1 isn't split
    2  after a relaunch the session reads as empty, as Chrome's does, while
       the kept rule still stops requests; given again unchanged, WebKit
       compiles nothing; taken away, requests go through. A second
       extension, whose worker WebKit never starts at launch, sets one too
    3  not given again, the kept rule goes 30 s after the extension loaded;
       the second extension's goes too, Search starting its worker to take
       it away
    4  kept rules give way to dynamic rules up to WebKit's limit, which
       holds 29,999 of each kind apart: last launch's are dropped, this
       launch's go back to being session rules and still stop the ad

Nothing leaves this Mac: the page and the "ad" are both served here.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import blocker_bench as b  # noqa: E402

b.W = "session-kept"
b.SUPPORT = f"{b.HOME}/Library/Application Support/Search ({b.W})"
b.SUITE = f"com.officecommun.search.test.{b.W}"
b.SOCK = f"{b.SUPPORT}/bench.sock"

def fnv(name):
    h = 2166136261
    for c in name: h = ((h ^ ord(c)) * 16777619) & 0xFFFFFFFF
    return h
H = fnv(b.W)
CONTROLLER = Path(os.path.expanduser(f"~/Library/WebKit/com.officecommun.search/WebExtensions/5E4C{H >> 16:04X}-{H & 0xFFFF:04X}-4000-8000-000000000002"))

class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"<!doctype html><title>page</title>" if self.path == "/" else b"// an ad"
        self.send_response(200); self.send_header("Content-Type", "text/html" if self.path == "/" else "text/javascript")
        self.send_header("Access-Control-Allow-Origin", "*"); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass

def serve():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server.server_port

PAGE = f"http://127.0.0.1:{serve()}/"
ADS_PORT = serve()
AD = f"http://localhost:{ADS_PORT}/ad.js"

SESSION_RULE = {"id": 7, "priority": 1, "action": {"type": "block"},
                "condition": {"urlFilter": f"|http://localhost:{ADS_PORT}/ad.js", "resourceTypes": ["xmlhttprequest", "script", "other"]}}
DYNAMIC_RULE = {"id": 7, "priority": 1, "action": {"type": "block"},
                "condition": {"urlFilter": f"|http://localhost:{ADS_PORT}/other.js"}}
# A choice in a regex, which WebKit refuses: the shim splits it into one rule
# per choice, kept together under this rule's id.
SPLIT_RULE = {"id": 8, "priority": 1, "action": {"type": "block"},
              "condition": {"regexFilter": f"^http://localhost:{ADS_PORT}/(one|two)\\.js", "resourceTypes": ["xmlhttprequest"]}}
# The same choice in a redirect that says \1: split, "one" would have no
# group for it. Left whole, as the plain way leaves it, for WebKit to refuse.
BACKREF_RULE = {"id": 9, "priority": 1,
                "action": {"type": "redirect", "redirect": {"regexSubstitution": f"http://localhost:{ADS_PORT}/\\1.txt"}},
                "condition": {"regexFilter": f"^http://localhost:{ADS_PORT}/(one|two)\\.js", "resourceTypes": ["xmlhttprequest"]}}
QUIET_RULE = {"id": 3, "priority": 1, "action": {"type": "block"},
              "condition": {"urlFilter": f"|http://localhost:{ADS_PORT}/quiet.js", "resourceTypes": ["xmlhttprequest", "script", "other"]}}

def extension(folder, name="Session rules probe", listens=True):
    folder.mkdir(parents=True)
    (folder / "manifest.json").write_text(json.dumps({
        "manifest_version": 3, "name": name, "version": "1.0",
        "permissions": ["declarativeNetRequest"], "host_permissions": ["<all_urls>"],
        "background": {"service_worker": "worker.js"},
    }))
    # A listener, so WebKit starts the worker at each launch, as uBOL's.
    # Without one, WebKit leaves it asleep until something needs it.
    (folder / "worker.js").write_text("chrome.runtime.onStartup.addListener(() => {});\n" if listens else "// nothing to start for\n")
    (folder / "page.html").write_text("<!doctype html><title>probe</title>")

class T:
    def __init__(self): self.passed = self.failed = 0
    def ok(self, name, cond, extra=""):
        if cond: self.passed += 1; print("  ok  ", name)
        else: self.failed += 1; print("  FAIL", name, extra)

ext_id = quiet_id = None

def dnr(js, on=None):
    """Runs `js` (an async body with `dnr` in scope) in the extension's page."""
    tab = b.cmd({"do": "ext-page", "id": on or ext_id, "path": "page.html"})["id"][:8]
    b.cmd({"do": "wait", "id": tab, "seconds": 10})
    b.cmd({"do": "eval", "id": tab, "js": "(async () => { const dnr = chrome.declarativeNetRequest; try { window.__r = JSON.stringify({ v: await (async () => { %s })() }); } catch (e) { window.__r = JSON.stringify({ e: String(e) }); } })(); 0" % js})
    value = ""
    for _ in range(150):
        value = b.cmd({"do": "eval", "id": tab, "js": "window.__r || ''"}).get("value")
        if value: break
        time.sleep(0.1)
    b.cmd({"do": "close", "id": tab})
    out = json.loads(value or '{"e": "no answer"}')
    if "e" in out: raise RuntimeError(out["e"])
    return out.get("v")

def ids(rules): return sorted(r["id"] for r in rules)

def fetched(ad=AD):
    """'blocked' or 'through', for a new tab asking for the ad."""
    tab = b.cmd({"do": "open", "url": PAGE})["id"][:8]
    b.cmd({"do": "wait", "id": tab, "seconds": 5})
    b.cmd({"do": "eval", "id": tab, "js": "(() => { window.__b = ''; fetch(%s + '?' + Math.random(), { cache: 'no-store' }).then(() => { window.__b = 'through'; }, () => { window.__b = 'blocked'; }); return 0; })()" % json.dumps(ad)})
    said = ""
    for _ in range(50):
        said = b.cmd({"do": "eval", "id": tab, "js": "window.__b"}).get("value") or ""
        if said: break
        time.sleep(0.1)
    b.cmd({"do": "close", "id": tab})
    return said

QUIET = f"http://localhost:{ADS_PORT}/quiet.js"

def becomes(want, limit=20, ad=AD):
    t0 = time.monotonic()
    while time.monotonic() - t0 < limit:
        if fetched(ad) == want: return True
        time.sleep(0.5)
    return False

def compiled():
    """The compiled rule list's modification time, and any compile under way."""
    folder = CONTROLLER / ext_id
    data = folder / "DeclarativeNetRequestContentRuleList.data"
    return (data.stat().st_mtime if data.exists() else None,
            [p.name for p in folder.glob("ContentRuleList*")] if folder.exists() else [])

def why(since):
    """What Search and WebKit say, for a check that failed."""
    state = [{k: e[k] for k in ("name", "loaded", "errors", "reported")} for e in b.extensions()]
    return {"seconds": round(time.monotonic() - since), "compiled": compiled(), "extensions": state}

def main():
    global ext_id, quiet_id
    if not Path(b.APP).exists(): sys.exit(f"no {b.APP} — ./build.sh first")
    t = T()
    keep = Path(tempfile.mkdtemp(prefix="session-kept-"))
    try:
        for p in b.pids(): subprocess.run(["kill", p])
        b.wipe(); shutil.rmtree(CONTROLLER, ignore_errors=True)
        for k in ("bench", "welcomed"): b.defaults(k, "-bool", "true")
        b.defaults("shield", "-bool", "false")
        extension(keep / "ext")
        extension(keep / "quiet", "Session rules probe, asleep", listens=False)

        print("— launch 1: rules set")
        b.launch()
        ext_id = b.install_folder(keep / "ext")["id"]
        quiet_id = b.install_folder(keep / "quiet")["id"]
        limit = dnr("return dnr.MAX_NUMBER_OF_DYNAMIC_AND_SESSION_RULES")
        t.ok("WebKit says its limit is 30,000", limit == 30000, limit)
        t.ok("nothing stopped before any rule", becomes("through"))
        dnr("await dnr.updateSessionRules({ addRules: [%s] })" % json.dumps(SESSION_RULE))
        t.ok("a session rule stops the ad", becomes("blocked"))
        dnr("await dnr.updateDynamicRules({ addRules: [%s] })" % json.dumps(DYNAMIC_RULE))
        session = dnr("return await dnr.getSessionRules()")
        dynamic = dnr("return await dnr.getDynamicRules()")
        t.ok("getSessionRules lists the session rule, as given", session == [SESSION_RULE] or (ids(session) == [7] and session[0]["condition"] == SESSION_RULE["condition"]), session)
        t.ok("getDynamicRules lists only the dynamic rule of the same id", ids(dynamic) == [7] and dynamic[0]["condition"] == DYNAMIC_RULE["condition"], dynamic)
        t.ok("getSessionRules takes ruleIds", ids(dnr("return await dnr.getSessionRules({ ruleIds: [7] })")) == [7]
             and dnr("return await dnr.getSessionRules({ ruleIds: [99] })") == [])
        dnr("await dnr.updateSessionRules({ addRules: [%s] })" % json.dumps(SPLIT_RULE))
        t.ok("a rule the shim splits is listed once, under its own id", ids(dnr("return await dnr.getSessionRules()")) == [7, 8])
        dnr("await dnr.updateSessionRules({ addRules: [%s] })" % json.dumps(BACKREF_RULE))
        t.ok("a redirect that says \\1 isn't split: WebKit refuses it whole", ids(dnr("return await dnr.getSessionRules()")) == [7, 8])
        t.ok("the ad is still stopped", becomes("blocked"))
        b.quit()

        print("— launch 2: given again, then taken away")
        b.launch(); b.until_loaded()
        t.ok("the session reads as empty after a relaunch", dnr("return await dnr.getSessionRules()") == [])
        t.ok("the kept rule stops the ad meanwhile", becomes("blocked"))
        time.sleep(3)
        before = compiled()
        dnr("await dnr.updateSessionRules({ addRules: [%s, %s] })" % (json.dumps(SESSION_RULE), json.dumps(SPLIT_RULE)))
        time.sleep(3)
        after = compiled()
        t.ok("given again unchanged: listed again", ids(dnr("return await dnr.getSessionRules()")) == [7, 8])
        t.ok("given again unchanged: WebKit compiled nothing", before[0] is not None and before == after, (before, after))
        t.ok("the dynamic rule is untouched", ids(dnr("return await dnr.getDynamicRules()")) == [7])
        dnr("await dnr.updateSessionRules({ removeRuleIds: [7, 8] })")
        t.ok("taken away: listed no more", dnr("return await dnr.getSessionRules()") == [])
        t.ok("taken away: the ad goes through", becomes("through"))
        dnr("await dnr.updateSessionRules({ addRules: [%s] })" % json.dumps(SESSION_RULE))
        t.ok("given once more: stopped again", becomes("blocked"))
        dnr("await dnr.updateSessionRules({ addRules: [%s] })" % json.dumps(QUIET_RULE), quiet_id)
        t.ok("the second extension's rule stops its ad", becomes("blocked", ad=QUIET))
        b.quit()

        print("— launch 3: not given again")
        b.launch(); b.until_loaded()
        loaded = time.monotonic()
        t.ok("kept from the last launch: still stopped at first", fetched() == "blocked")
        t.ok("the second extension's too", fetched(QUIET) == "blocked")
        time.sleep(max(0, 33 - (time.monotonic() - loaded)))
        t.ok("30 s on, not given again: the ad goes through", becomes("through"), why(loaded) if fetched() != "through" else "")
        t.ok("and the session is empty", dnr("return await dnr.getSessionRules()") == [])
        t.ok("the dynamic rule stays", ids(dnr("return await dnr.getDynamicRules()")) == [7])
        t.ok("the second extension's goes once Search starts its worker", becomes("through", 15, QUIET), why(loaded) if fetched(QUIET) != "through" else "")
        print(f"        ({time.monotonic() - loaded:.0f} s after its load)")
        t.ok("and its session is empty", dnr("return await dnr.getSessionRules()", quiet_id) == [])
        dnr("await dnr.updateSessionRules({ addRules: [%s] })" % json.dumps(SESSION_RULE))
        t.ok("given for the next launch", becomes("blocked"))
        b.quit()

        print("— launch 4: up to the limit")
        b.launch(); b.until_loaded()
        t.ok("kept from the last launch: stopped at first", fetched() == "blocked")
        # WebKit refuses a set that reaches its limit, so it holds one rule
        # fewer. The one dynamic rule and this many more fill it; with a
        # kept rule beside them they are one past.
        most = limit - 1
        more = most - 1
        fill = """await dnr.updateDynamicRules({ addRules: Array.from({ length: %d }, (_, i) => ({ id: 100 + i, priority: 1,
            action: { type: "block" }, condition: { urlFilter: "|http://localhost:%d/filler-" + i + ".js" } })) });
          return (await dnr.getDynamicRules()).length""" % (more, ADS_PORT)
        empty = "await dnr.updateDynamicRules({ removeRuleIds: Array.from({ length: %d }, (_, i) => 100 + i) })" % more
        added = dnr(fill)
        t.ok("before it's given: dynamic rules up to the limit are taken", added == most, added)
        t.ok("last launch's kept rule gave way: the ad goes through", becomes("through"))
        dnr(empty)
        dnr("await dnr.updateSessionRules({ addRules: [%s, %s] })" % (json.dumps(SESSION_RULE), json.dumps(SPLIT_RULE)))
        t.ok("given: stopped again", becomes("blocked"))
        added = dnr(fill)
        t.ok("after it's given: dynamic rules up to the limit are taken", added == most, added)
        t.ok("this launch's went back to session rules, listed as before", ids(dnr("return await dnr.getSessionRules()")) == [7, 8])
        t.ok("and still stop the ad", becomes("blocked"))
        dnr(empty)
        t.ok("the extension's own dynamic rule stays", ids(dnr("return await dnr.getDynamicRules()")) == [7])
        dnr("await dnr.updateSessionRules({ removeRuleIds: [7, 8] })")
        t.ok("taken away, they go", becomes("through") and dnr("return await dnr.getSessionRules()") == [])
    except Exception as error:
        t.ok("ran to the end", False, error)
    finally:
        b.quit(); b.wipe(); shutil.rmtree(CONTROLLER, ignore_errors=True); shutil.rmtree(keep, ignore_errors=True)
    print(f"{t.passed} passed, {t.failed} failed")
    sys.exit(1 if t.failed else 0)

if __name__ == "__main__":
    main()
