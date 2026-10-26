#!/usr/bin/env python3
"""A website an extension lists, talking to it (#496), and an extension's
tab groups, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/external_messaging.py`. It
runs a copy of build/Search.app under a bundle id of its own (WebKit stops
an extension's worker a few seconds after it starts under Search's real id
in a test run), in a world of its own with split_view.py's harness, started
hidden; the copy, its WebKit folders and the world are removed afterwards.

The extension, written here, lists http://127.0.0.1/* and answers on
runtime.onMessageExternal: at once, later (return true), and from an async
function. What is checked:

- chrome.runtime on a listed page only; none on localhost, which isn't;
- replies reach Chrome's callback and the promise, async ones included,
  with the page's origin as the sender's;
- a message for an extension that isn't there fails as in Chrome, with
  "Receiving end does not exist" in lastError and a rejected promise, not
  an empty answer: claude.ai's sign-in asks Anthropic's own build of
  Claude in Chrome first and stopped at the empty answer (16 Oct 2026,
  the approve button spun for good);
- chrome.tabs.group makes a group and tabGroups.query finds it, so a
  second call reuses it (Claude in Chrome can't act on a tab outside a
  group of its own). Tab groups are always on since the Settings rework
  (5e8ea674, no switch): an "off" stored by an older Search changes
  nothing, the column draws the group's heading, and folded the group
  keeps its tabs and the extension still finds it.
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

sv.use("external-messaging")
BUNDLE = "com.officecommun.search.exttest"
work = Path(tempfile.mkdtemp(prefix="search-external-"))
NOWHERE = "abcdefghijklmnopabcdefghijklmnop"

FILES = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "Listed", "version": "1.0",
        "permissions": ["tabs", "tabGroups"],
        "background": {"service_worker": "background.js"},
        "externally_connectable": {"matches": ["http://127.0.0.1/*"]},
    }),
    "background.js": """
const heard = [];
chrome.runtime.onMessageExternal.addListener((message, sender, sendResponse) => {
  const type = message && message.type;
  heard.push(type);
  if (type === "ping") { sendResponse({ pong: true, origin: sender.origin, tab: !!sender.tab }); return; }
  if (type === "later") { setTimeout(() => sendResponse({ later: true }), 400); return true; }
  if (type === "async") {
    (async () => { await new Promise((r) => setTimeout(r, 300)); sendResponse({ async: true }); })();
    return true;
  }
  if (type === "heard") { sendResponse(heard.slice()); return; }
  if (type === "group") {
    (async () => {
      try {
        const known = await chrome.tabGroups.query({ title: "Claude" });
        const id = await chrome.tabs.group(known.length ? { tabIds: [sender.tab.id], groupId: known[0].id } : { tabIds: [sender.tab.id] });
        await chrome.tabGroups.update(id, { title: "Claude", color: "orange" });
        const tab = await chrome.tabs.get(sender.tab.id);
        const found = await chrome.tabGroups.query({ title: "Claude" });
        sendResponse({ id, groupId: tab.groupId, found: found.map((g) => g.id) });
      } catch (e) { sendResponse({ error: String(e && e.message || e) }); }
    })();
    return true;
  }
});
""",
}

# The page's side, in its own world: each call keeps its outcome on
# window.__r[key], read in a second eval (eval can't wait on a promise).
ASK = """(function (key, id, message, how) {
  window.__r = window.__r || {};
  const keep = (v) => { window.__r[key] = v; };
  if (how === "callback") {
    chrome.runtime.sendMessage(id, message, (reply) => keep({ reply: reply === undefined ? null : reply,
      error: chrome.runtime.lastError ? chrome.runtime.lastError.message : null }));
  } else {
    chrome.runtime.sendMessage(id, message).then((reply) => keep({ reply: reply === undefined ? null : reply, error: null }),
      (e) => keep({ reply: null, error: String(e && e.message || e) }));
  }
  return 1;
})(%s, %s, %s, %s)"""

# claude.ai's sign-in, as its page does it: each id in turn, the next one
# only on an error, done at the first answer that isn't a refusal.
LOOP = """(async function (ids) {
  window.__r = window.__r || {};
  for (const id of ids) {
    let reply;
    try {
      reply = await new Promise((resolve, reject) => chrome.runtime.sendMessage(id, { type: "ping" },
        (r) => chrome.runtime.lastError ? reject(new Error(chrome.runtime.lastError.message)) : resolve(r)));
    } catch (e) { continue; }
    if (reply?.success !== false) { window.__r.loop = { stoppedAt: id, reply: reply === undefined ? null : reply }; return; }
  }
  window.__r.loop = { stoppedAt: null };
})(%s); 1"""


def probe_copy():
    """build/Search.app under a bundle id of its own, signed ad hoc."""
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def ev(id, js):
    return sv.cmd({"do": "eval", "id": id, "js": js}).get("value")


def ask(tab, key, ext, message, how="callback", within=6):
    ev(tab, ASK % (json.dumps(key), json.dumps(ext), json.dumps(message), json.dumps(how)))
    until = time.time() + within
    while time.time() < until:
        got = ev(tab, f"JSON.stringify((window.__r || {{}})[{json.dumps(key)}] || null)")
        if got and got != "null": return json.loads(got)
        time.sleep(0.2)
    return None


def groups(): return sv.cmd({"do": "group"})


def column(name):
    path = str(work / f"{name}.png")
    sv.cmd({"do": "column", "path": path, "height": 500})
    return Path(path).read_bytes()


def main():
    t = sv.T()
    folder = work / "ext"
    folder.mkdir()
    for name, body in FILES.items(): (folder / name).write_text(body)
    sv.APP = probe_copy()
    try:
        # An "off" left by a Search from before groups were always on.
        sv.setup(sidebar=True, **{"tabs.groups": False})
        sv.launch()
        sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
        ext = None
        for _ in range(60):
            ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == "Listed" and x["loaded"]), None)
            if ext: break
            time.sleep(0.25)
        t.ok("the extension loads", ext is not None)
        if not ext: return t
        ID = ext["id"]

        listed = sv.page("listed")
        port = sv.BASE.rsplit(":", 1)[1]
        other = sv.sp("open", url=f"http://localhost:{port}/other")["resultID"]; time.sleep(1.5)
        t.ok("chrome.runtime on the listed page", ev(listed, "typeof (window.chrome && chrome.runtime && chrome.runtime.sendMessage)") == "function")
        t.ok("no chrome on a page nobody lists", ev(other, "typeof window.chrome") == "undefined")

        r = ask(listed, "ping", ID, {"type": "ping"})
        t.ok("an answer at once reaches the callback, with the page's origin",
             r and r["reply"] and r["reply"].get("pong") and r["reply"].get("origin") == sv.BASE and r["reply"].get("tab") and not r["error"], r)
        r = ask(listed, "later", ID, {"type": "later"})
        t.ok("an answer later (return true) reaches the callback", r and r["reply"] == {"later": True} and not r["error"], r)
        r = ask(listed, "async", ID, {"type": "async"}, how="promise")
        t.ok("an answer from an async function resolves the promise", r and r["reply"] == {"async": True} and not r["error"], r)

        r = ask(listed, "nowhere", NOWHERE, {"type": "ping"})
        t.ok("no such extension: lastError, as in Chrome",
             r and r["reply"] is None and "Receiving end does not exist" in (r["error"] or ""), r)
        r = ask(listed, "nowhere2", NOWHERE, {"type": "ping"}, how="promise")
        t.ok("no such extension: the promise rejects", r and "Receiving end does not exist" in (r["error"] or ""), r)

        ev(listed, LOOP % json.dumps([NOWHERE, ID]))
        loop = None
        for _ in range(30):
            got = ev(listed, "JSON.stringify((window.__r || {}).loop || null)")
            if got and got != "null": loop = json.loads(got); break
            time.sleep(0.2)
        t.ok("claude.ai's loop goes on to the extension that is there", loop and loop["stoppedAt"] == ID and loop["reply"].get("pong"), loop)
        heard = ask(listed, "heard", ID, {"type": "heard"})
        t.ok("the extension heard every message meant for it, and nothing else",
             heard and heard["reply"] == ["ping", "later", "async", "ping", "heard"], heard)

        # Tab groups: always on, whatever an older Search stored.
        second = sv.page("second")
        time.sleep(1)
        before = column("before")
        g1 = ask(listed, "group1", ID, {"type": "group"}, within=8)
        r1 = g1 and g1["reply"] or {}
        state = groups()
        made = [g for g in state["groups"] if g["name"] == "Claude"]
        t.ok("groups on with no switch (an old stored off counts for nothing): tabs.group makes a group",
             r1.get("id") and not r1.get("error") and state["on"] is True and len(made) == 1, (g1, state))
        t.ok("the tab says it is in it, and query finds it",
             r1.get("groupId") == r1.get("id") and r1.get("found") == [r1.get("id")], r1)
        g2 = ask(second, "group2", ID, {"type": "group"}, within=8)
        r2 = g2 and g2["reply"] or {}
        made = [g for g in groups()["groups"] if g["name"] == "Claude"]
        t.ok("the extension finds its group again, no second one",
             r2.get("id") == r1.get("id") and len(made) == 1 and len(made[0]["tabs"]) == 2, (r2, made))
        after = column("after")
        t.ok("the column draws the group's heading", after != before)
        folded = sv.cmd({"do": "group", "name": "Claude", "fold": True}); time.sleep(0.8)
        made = [g for g in folded["groups"] if g["name"] == "Claude"]
        t.ok("folded, the group keeps both tabs", len(made) == 1 and made[0]["collapsed"] and len(made[0]["tabs"]) == 2, folded)
        g3 = ask(listed, "group3", ID, {"type": "group"}, within=8)
        r3 = g3 and g3["reply"] or {}
        made = [g for g in groups()["groups"] if g["name"] == "Claude"]
        t.ok("folded, the extension still finds its group",
             r3.get("id") == r1.get("id") and r3.get("groupId") == r1.get("id") and len(made) == 1, (r3, made))
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
