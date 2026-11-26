#!/usr/bin/env python3
"""chrome.storage.session survives Search restarting an extension itself
(idea 1322), in a hidden probe, without the network.

Build first (`./build.sh debug`), then
`lockf -t 900 /private/tmp/claude-501/search-probe.lock.N python3 Tests/extension_session_restart.py`.

When an extension's worker won't start or stops answering, Search unloads
and loads the extension again (Extensions.revive). WebKit empties
chrome.storage.session with the unload, which Chrome never does for a worker
it restarts: Dashlane keeps its unlocked session there and asked to sign in
again in the middle of the day. Checked, with a local extension:

- session and local values written from its page are there after a worker
  restart Search makes (the page's own "background.revive"), and the
  restart is on record in the extension's errors;
- switching it off and on still empties session storage, as in Chrome.
"""
import json
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("extension-session-restart")
NAME = "SessionKeep"
FILES = {
    "manifest.json": json.dumps({"manifest_version": 3, "name": NAME, "version": "1.0",
                                 "background": {"service_worker": "sw.js"}, "permissions": ["storage"]}),
    "sw.js": "chrome.runtime.onMessage.addListener((m, s, reply) => { if (m === 'hi') reply('hello'); });",
    "page.html": "<!doctype html><title>page</title><p>page",
}


def extension():
    st = sv.cmd({"do": "extensions"})
    return next((e for e in st["extensions"] if e["name"] == NAME), None)


def page(id):
    for _ in range(30):
        e = extension()
        if e and e["loaded"]: break
        time.sleep(0.5)
    p = sv.cmd({"do": "ext-page", "id": id, "path": "page.html"})["id"]
    sv.cmd({"do": "wait", "id": p, "seconds": 10})
    time.sleep(0.5)
    return p


def run(p, body):
    sv.ev(p, "window.__o = 'pending'; (async () => { try { window.__o = JSON.stringify(await (async () => { %s })()); }"
             " catch (e) { window.__o = 'ERR ' + e; } })(); true" % body)
    for _ in range(40):
        v = sv.ev(p, "window.__o")
        if v != "pending": return json.loads(v) if v and not v.startswith("ERR") else v
        time.sleep(0.25)


READ = "return {session: await chrome.storage.session.get(null), local: (await chrome.storage.local.get('l')).l || null};"


def read(id):
    p = page(id)
    got = run(p, READ)
    sv.cmd({"do": "close", "id": p})
    return got


def main():
    t = sv.T()
    work = Path(tempfile.mkdtemp(prefix="search-session-restart-"))
    for name, text in FILES.items():
        (work / name).write_text(text)
    try:
        sv.setup()
        sv.launch()
        sv.cmd({"do": "ext-folder", "path": str(work), "yes": True})
        for _ in range(40):
            if extension(): break
            time.sleep(0.5)
        e = extension()
        t.ok("the extension installed", e is not None, e)
        id = e["id"]
        p = page(id)
        run(p, "await chrome.storage.session.set({a: 'one', b: {deep: [1, 2]}}); await chrome.storage.local.set({l: 'kept'}); return true;")
        t.ok("written", read(id) == {"session": {"a": "one", "b": {"deep": [1, 2]}}, "local": "kept"}, read(id))
        p = page(id)
        said = run(p, "return await chrome.runtime.sendNativeMessage('search', {api: 'background.revive', args: []});")
        sv.cmd({"do": "close", "id": p})
        t.ok("Search restarted it", said == {"value": True}, said)
        time.sleep(3)
        got = read(id)
        t.ok("session storage kept through the restart", got and got["session"] == {"a": "one", "b": {"deep": [1, 2]}}, got)
        t.ok("local storage kept through the restart", got and got["local"] == "kept", got)
        restarted = [x for x in (extension() or {}).get("reported", []) if "restarted" in str(x)]
        t.ok("the restart is on record", bool(restarted), extension())
        sv.cmd({"do": "ext-enable", "id": id, "on": False})
        time.sleep(1)
        sv.cmd({"do": "ext-enable", "id": id, "on": True})
        time.sleep(2)
        got = read(id)
        t.ok("off and on empties session storage, as in Chrome", got and got["session"] == {} and got["local"] == "kept", got)
    finally:
        sv.finish()
    return t


if __name__ == "__main__":
    t = main()
    t.done()
    sys.exit(1 if t.failed else 0)
