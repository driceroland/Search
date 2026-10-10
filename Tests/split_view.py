#!/usr/bin/env python3
"""Split View, checked through Search's own model in a hidden probe.

Build first (`./build.sh` or `./build.sh debug`), then run
`python3 Tests/split_view.py`. The app is started hidden in a world of its
own (SEARCH_PROBE=split-tests-<checkout>, see use()), driven through
./bench's socket, and quit;
its settings and files are removed afterwards. Nothing here makes, shows or
brings forward a window: what can only be seen — dragging onto a page's
edge, the divider under the pointer, the motion itself — is checked by
hand on a release candidate.
"""

import hashlib
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import uuid
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
ROOT = Path(__file__).resolve().parents[1]
APP = str(ROOT / "build" / "Search.app")
HOME = os.path.expanduser("~")
def use(name):
    """This checkout's own world for a suite: the name, then a tag made from
    the checkout's path. Two checkouts testing at once (a worktree beside
    the main one, another session's) share no socket, settings or folder,
    so a run in one is never answered by the other's build. A suite that
    wants a world apart from the split suite's calls it with its own name."""
    global W, SUPPORT, SUITE, SOCK
    W = f"{name}-{hashlib.sha1(str(ROOT).encode()).hexdigest()[:8]}"
    SUPPORT = f"{HOME}/Library/Application Support/Search ({W})"
    SUITE = f"com.officecommun.search.test.{W}"
    SOCK = f"{SUPPORT}/bench.sock"
use("split-tests")
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        port = self.server.server_port
        if self.path == "/asker":
            body = f"<!doctype html><title>asker</title><iframe src='http://localhost:{port}/frame'></iframe>".encode()
        elif self.path == "/long":
            body = b"<!doctype html><title>long</title><div style='height:20000px'>long</div>"
        elif self.path == "/frame":
            body = b"<!doctype html><script>setTimeout(function(){ alert('from the frame') }, 1200)</script>"
        else:
            body = f"<!doctype html><title>{self.path.strip('/')}</title><p>{self.path}".encode()
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
srv = ThreadingHTTPServer(("127.0.0.1", 0), H); threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"
# Only ever a probe of this world: the one this run started, or one a run
# before left holding this world's socket. Never the Search someone is using,
# even one running from this very build (see running()).
started = set()
def running(): return set(subprocess.run(["pgrep", "-f", APP + "/Contents/MacOS"], capture_output=True, text=True).stdout.split())
def holding(): return set(subprocess.run(["lsof", "-t", "--", SOCK], capture_output=True, text=True).stdout.split()) if os.path.exists(SOCK) else set()
def pids(): return sorted((started & running()) | (holding() & running()))
WEBKIT = f"{HOME}/Library/WebKit/com.officecommun.search"
def stores():
    """The WebKit stores this world's runs made, where WebKit keeps them and
    named as the app names them (Store.probeStore, Spaces.store): its
    websites', its extensions', and one for each of its spaces with sign-ins
    of its own, read from its own list of spaces and of spaces it was still
    erasing. Only those: a real Search's spaces keep their stores beside
    them, and a store is never guessed at by its look."""
    h = 2166136261
    for byte in W.encode(): h = ((h ^ byte) * 16777619) & 0xFFFFFFFF
    probe = lambda kind: f"5E4C{h >> 16:04X}-{h & 0xFFFF:04X}-4000-8000-{kind:012X}"
    found = [f"{WEBKIT}/WebsiteDataStore/{probe(1).lower()}", f"{WEBKIT}/WebExtensions/{probe(2)}"]
    ids = []
    try:
        ids += [space["id"] for space in json.load(open(f"{SUPPORT}/spaces.json")) if space.get("sharesSignIns") is not True]
    except (OSError, ValueError, TypeError, KeyError):
        pass
    erasing = subprocess.run(["defaults", "read", SUITE, "spaces.erasing"], capture_output=True, text=True).stdout
    ids += re.findall(r"[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}", erasing)
    for id in ids:
        try: id = str(uuid.UUID(id))
        except (ValueError, AttributeError, TypeError): continue
        # The first space is signed in where the world is: no store of its own.
        if id != FIRST_SPACE:
            found.append(f"{WEBKIT}/WebsiteDataStore/{id}")
    return found
# The real Search's folder, beside whose stores these are removed.
REAL = f"{HOME}/Library/Application Support/Search"
FIRST_SPACE = "00000000-0000-0000-0000-000000000001"
def guarded():
    """Store ids no wipe removes, whatever stores() names: every space of the
    real Search's own list, and the first space's fixed id. A wrong hash, or
    a test world's list holding a real space's id, then never reaches a real
    space's sign-ins: rm -rf runs in the folder where those live."""
    ids = {FIRST_SPACE}
    try:
        ids |= {str(uuid.UUID(space["id"])) for space in json.load(open(f"{REAL}/spaces.json"))}
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        pass
    return ids
def wipe():
    # The stores first: which spaces had one is in the folder and settings
    # about to go.
    keep = guarded()
    for path in stores():
        if os.path.basename(path).lower() in keep:
            print(f"wipe: not removing {path}: the real Search's spaces use that id", file=sys.stderr)
            continue
        subprocess.run(["rm", "-rf", path])
    subprocess.run(["rm", "-rf", SUPPORT]); subprocess.run(["defaults", "delete", SUITE], capture_output=True)
def probe(pid):
    names = subprocess.run(["lsof", "-a", "-U", "-p", pid, "-Fn"], capture_output=True, text=True).stdout
    return any(n.startswith("n") and "/Search (" in n and n.endswith("/bench.sock") for n in names.splitlines())
def main_checkout():
    git = lambda *a: subprocess.run(["git", "-C", str(ROOT), "rev-parse", *a], capture_output=True, text=True).stdout.strip()
    return git("--git-dir") != "" and Path(git("--absolute-git-dir")) == Path(ROOT, git("--git-common-dir")).resolve()
# Someone's own Search running from this build: no probe starts beside it
# from here. Run the tests from a worktree of your own instead.
if main_checkout() and any(not probe(p) for p in running()):
    sys.exit(f"{APP} is in use by a Search that isn't a probe. Run the tests from a worktree (git worktree add).")
def setup(**prefs):
    for p in pids(): subprocess.run(["kill", p])
    started.clear()
    time.sleep(1); wipe()
    for k in ["bench", "welcomed"]: subprocess.run(["defaults", "write", SUITE, k, "-bool", "true"])
    for k, v in prefs.items(): subprocess.run(["defaults", "write", SUITE, k, "-bool", "true" if v else "false"])
def launch():
    if os.path.exists(SOCK): os.remove(SOCK)
    before = running()
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={W}", APP])
    for _ in range(150):
        if os.path.exists(SOCK): break
        time.sleep(0.1)
    time.sleep(2)
    # Whatever came up from this build just now and holds this world's socket.
    started.update((running() - before) & holding())
def quit():
    try: cmd({"do": "quit"})
    except Exception: pass
    for _ in range(30):
        if not pids(): break
        time.sleep(0.2)
    for p in pids(): subprocess.run(["kill", p])
def cmd(req):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as c:
        c.settimeout(30); c.connect(f"{SUPPORT}/bench.sock"); c.sendall(json.dumps(req).encode() + b"\n")
        data = b""
        while True:
            ch = c.recv(65536)
            if not ch: break
            data += ch
    a = json.loads(data.split(b"\n", 1)[0] or b"{}")
    if "error" in a: raise RuntimeError(f"{req}: {a['error']}")
    return a
def sp(action, **f): return cmd({"do": "split", "action": action, **f})
def page(name):
    r = sp("open", url=f"{BASE}/{name}")["resultID"]; time.sleep(0.7); return r
def session(space=None):
    f = f"{SUPPORT}/session.json" if not space else f"{SUPPORT}/session-{space}.json"
    return json.load(open(f))
class T:
    def __init__(self): self.passed = self.failed = 0
    def ok(self, name, cond, extra=""):
        if cond: self.passed += 1; print("  ok  ", name)
        else: self.failed += 1; print("  FAIL", name, extra)
    def done(self):
        print(f"{self.passed} passed, {self.failed} failed")
def finish():
    quit(); time.sleep(0.5); wipe()


def frames(st): return {f["id"]: f for f in st["paneFrames"]}
def order(st): return [x["id"] for x in st["tabs"]]
def url(st, id): return next(x["url"] for x in st["tabs"] if x["id"] == id)
def ev(id, js): return cmd({"do": "eval", "id": id, "js": js}).get("value")
def qs(): return sp("state")["questions"]
def asked(id, within=10):
    """The questions once page id has one up: a page's question reaches the
    app a moment after the page asks, longer on a busy machine."""
    until = time.time() + within
    while not any(q["tab"] == id for q in qs()) and time.time() < until: time.sleep(0.1)
    return qs()
def sample(n=12, every=0.03, within=3):
    """n looks at what moves, from the first that shows something moving:
    on a busy machine the move can start a while after it was asked for.
    Nothing moving by `within` seconds, and the n looks are taken then."""
    out = []; until = time.time() + within
    while len(out) < n:
        m = sp("motion")["motion"]
        if m or out or time.time() > until: out.append(m)
        time.sleep(every)
    return out


def case_slice1(t):
    """pairs, the file, off keeps pairs"""
    setup(splitView=True); launch()
    a = page("a"); b = page("b"); c = page("c")
    st = sp("pair", id=b, **{"with": a}, side="right")
    p = st["splits"][0]
    t.ok("pair is [a, b], horizontal, even", p["tabs"] == [a, b] and p["axis"] == "horizontal" and p["sizes"] == [0.5, 0.5], p)
    t.ok("focused is the dragged page", p["focused"] == b, p)
    st = sp("focus", id=a); t.ok("focus a remembered", st["splits"][0]["focused"] == a)
    sp("fraction", split=p["id"], fraction=0.3)
    st = sp("select", id=c)
    t.ok("leaving the pair keeps its focus", st["splits"][0]["focused"] == a)
    sp("save"); s = session()
    urls = [e["url"] for e in s["tabs"]]
    ia, ib = urls.index(f"{BASE}/a"), urls.index(f"{BASE}/b")
    sv = s.get("splits", [])
    t.ok("file: pair by places, sizes, axis, focused", len(sv) == 1 and sv[0]["tabs"] == [ia, ib] and abs(sv[0]["sizes"][0] - 0.3) < 1e-9 and sv[0]["axis"] == "horizontal" and sv[0]["focused"] == ia, sv)
    # switch off keeps the pair
    st = sp("enabled", on=False)
    t.ok("off: pair kept in the model", len(st["splits"]) == 1, st["splits"])
    t.ok("off: both tabs in the row", a in st["displayedIDs"] and b in st["displayedIDs"])
    st = sp("select", id=a)
    t.ok("off: one page on screen", st["visibleIDs"] == [a], st["visibleIDs"])
    sp("save"); t.ok("off: still written", len(session().get("splits", [])) == 1)
    # relaunch with the switch off, then on
    quit(); launch()
    st = sp("state")
    ids = {t_["url"]: t_["id"] for t_ in st["tabs"]}
    a, b, c = ids[f"{BASE}/a"], ids[f"{BASE}/b"], ids[f"{BASE}/c"]
    t.ok("relaunch off: pair restored, waiting", len(st["splits"]) == 1 and st["splits"][0]["tabs"] == [a, b] and abs(st["splits"][0]["sizes"][0] - 0.3) < 1e-9, st["splits"])
    t.ok("relaunch off: focus restored", st["splits"][0]["focused"] == a)
    st = sp("enabled", on=True)
    st = sp("select", id=a)
    t.ok("on again: pair on screen", set(st["visibleIDs"]) == {a, b}, st["visibleIDs"])
    # off, pull the pair apart, on: it goes
    sp("enabled", on=False)
    sp("move", id=c, to=[x["id"] for x in sp("state")["tabs"]].index(b))
    st = sp("state"); order = [x["id"] for x in st["tabs"]]
    t.ok("off: c moved between a and b", order.index(c) == order.index(a) + 1, order)
    st = sp("enabled", on=True)
    t.ok("on: a pair that came apart is dropped", len(st["splits"]) == 0, st["splits"])
    # empty pane: never written
    sp("select", id=c); st = sp("start")
    t.ok("⌃⌘S: pair with an empty page", len(st["splits"]) == 1)
    sp("save"); s = session()
    t.ok("empty page not written, nor its pair", "about:blank" not in json.dumps(s) and len(s.get("splits", [])) == 0, s.get("splits"))


def case_slice1b(t):
    """an old file, pins, groups"""
    setup(splitView=True, **{"tabs.groups": True})
    os.makedirs(SUPPORT, exist_ok=True)
    legacy = {"tabs": [{"url": f"{BASE}/x", "title": "x"}, {"url": f"{BASE}/y", "title": "y"}, {"url": "about:blank", "title": ""}],
              "active": 1, "splits": [{"left": 0, "right": 1, "fraction": 0.35}]}
    json.dump(legacy, open(f"{SUPPORT}/session.json", "w"))
    launch()
    st = sp("state"); ids = {x["url"]: x["id"] for x in st["tabs"]}
    x, y = ids.get(f"{BASE}/x"), ids.get(f"{BASE}/y")
    t.ok("#381's first file shape still reads", len(st["splits"]) == 1 and st["splits"][0]["tabs"] == [x, y] and abs(st["splits"][0]["sizes"][0] - 0.35) < 1e-9, st["splits"])
    t.ok("its about:blank entry is dropped", not any(e["blank"] for e in st["tabs"]), [e["url"] for e in st["tabs"]])
    c = page("c")
    cmd({"do": "pin", "id": c}); sp("select", id=c); st = sp("start")
    t.ok("pin: split with a copy, pin kept out of the pair", not any(c in p["tabs"] for p in st["splits"]) and cmd({"do": "pin", "id": c, "home": True})["pin"] != "")
    sp("dismiss")
    st = sp("group", id=y); g = st["groups"][-1]["id"]
    gid = dict(zip([e["id"] for e in st["tabs"]], st["groupIDs"]))
    t.ok("half into a group: both go, pair holds", gid[x] == g and gid[y] == g and len(st["splits"]) == 1)
    sp("save"); quit(); launch()
    st = sp("state")
    t.ok("grouped pair survives a relaunch", len(st["splits"]) == 1, st["splits"])


def case_slice2(t):
    """the stage and its divider"""
    setup(splitView=True); launch()
    a = page("a"); b = page("b"); c = page("c")
    sp("select", id=a); time.sleep(0.5)
    st = sp("state"); fa = frames(st).get(a)
    t.ok("one page fills the stage", fa is not None and fa["x"] == 0, st["paneFrames"])
    full = fa["width"]
    st = sp("pair", id=b, **{"with": a}, side="right"); time.sleep(0.8); st = sp("state")
    f = frames(st)
    t.ok("two pages, side by side", a in f and b in f and f[a]["x"] == 0 and f[b]["x"] > f[a]["width"], st["paneFrames"])
    gut = f[b]["x"] - f[a]["width"]
    t.ok("a 7 pt gutter", abs(gut - 7) < 0.6, gut)
    t.ok("even halves", abs(f[a]["width"] - f[b]["width"]) < 1, (f[a]["width"], f[b]["width"]))
    x = f[a]["width"] + 3.5; y = f[a]["y"] + f[a]["height"] / 2
    # drag the divider left, hold
    st = sp("mouse", points=[[x, y], [x - 60, y], [x - 120, y], [x - 160, y]], hold=True, to="view"); time.sleep(0.3); st = sp("state")
    m = frames(st)
    t.ok("held: pages follow the hand", m[a]["width"] < f[a]["width"] - 140, (f[a]["width"], m[a]["width"]))
    t.ok("held: the pair isn't told yet", abs(st["splits"][0]["fraction"] - 0.5) < 1e-9, st["splits"][0]["fraction"])
    st = sp("mouse", points=[[x - 160, y]], resume=True, to="view"); time.sleep(0.3); st = sp("state")
    e = frames(st)
    t.ok("released: told once", st["splits"][0]["fraction"] < 0.45, st["splits"][0]["fraction"])
    t.ok("released: pages stay put", abs(e[a]["width"] - m[a]["width"]) < 1.5, (m[a]["width"], e[a]["width"]))
    # snap at even
    x2 = e[a]["width"] + 3.5
    room = full - 7
    st = sp("mouse", points=[[x2, y], [room / 2 + 3.5 - 30, y], [room / 2 + 3.5 - 10, y], [room / 2 + 3.5 - 10, y]], to="view"); time.sleep(0.3); st = sp("state")
    t.ok("snaps to even within 15 pt", abs(st["splits"][0]["fraction"] - 0.5) < 1e-6, st["splits"][0]["fraction"])
    # never narrower than 250
    x3 = frames(st)[a]["width"] + 3.5
    st = sp("mouse", points=[[x3, y], [200, y], [20, y], [20, y]], to="view"); time.sleep(0.3); st = sp("state")
    t.ok("a page stays at least 250 pt", abs(frames(st)[a]["width"] - 250) < 1, frames(st)[a]["width"])
    # double-click evens out
    x4 = frames(st)[a]["width"] + 3.5
    st = sp("mouse", points=[[x4, y], [x4, y]], clicks=2, to="view"); time.sleep(0.4); st = sp("state")
    t.ok("double-click evens out", abs(st["splits"][0]["fraction"] - 0.5) < 1e-6, st["splits"][0]["fraction"])
    # click in the other page focuses it
    sp("focus", id=a); f = frames(sp("state"))
    st = sp("mouse", points=[[f[b]["x"] + 100, y], [f[b]["x"] + 100, y]]); time.sleep(0.4); st = sp("state")
    t.ok("a click in the other page focuses it", st["activeID"] == b, st["activeID"])
    st = sp("keys", id=a); time.sleep(0.3); st = sp("state")
    t.ok("the keys going to the other page focus it", st["activeID"] == a, st["activeID"])
    sp("focus", id=b)
    # narrow window: focused page alone, pair kept
    cmd({"do": "ui", "sidebar": True}); cmd({"do": "resize", "width": 700, "height": 700, "steps": 1}); time.sleep(1); st = sp("state")
    t.ok("too narrow: the focused page alone", list(frames(st).keys()) == [b] and len(st["splits"]) == 1, (st["paneFrames"], st["splits"]))
    cmd({"do": "resize", "width": 1180, "height": 780, "steps": 1}); time.sleep(1); st = sp("state")
    cmd({"do": "ui", "sidebar": False}); time.sleep(1)
    t.ok("room again: both back", set(frames(st).keys()) == {a, b}, st["paneFrames"])
    # the stage isn't rebuilt: tab switches keep the same slots
    st = sp("select", id=c); time.sleep(0.4); st = sp("state")
    t.ok("a tab alone fills the stage again", list(frames(st).keys()) == [c] and abs(frames(st)[c]["width"] - full) < 1, st["paneFrames"])
    st = sp("select", id=a); time.sleep(0.4); st = sp("state")
    t.ok("back to the pair: both", set(frames(st).keys()) == {a, b})


def case_slice3(t):
    """the row"""
    setup(splitView=True); launch()
    a = page("a"); b = page("b"); c = page("c")
    sp("pair", id=b, **{"with": a}, side="right"); sp("focus", id=b)
    st = sp("select", id=c)
    st = sp("step", direction=-1)
    t.ok("⌃⇧Tab back into the pair: the page focused last", st["activeID"] == b, st["activeID"])
    st = sp("step", direction=1)
    t.ok("⌃Tab out of the pair: the next tab, not the other half", st["activeID"] == c, st["activeID"])
    sp("select", id=a)
    st = sp("state")
    t.ok("clicking a half still gives that half", st["activeID"] == a)
    sp("focus", id=b); time.sleep(0.8)


def case_slice4(t):
    """in and out"""
    setup(splitView=True); launch()
    a = page("a"); b = page("b"); c = page("c"); d = page("d")
    sp("select", id=a)
    st = sp("openIn", id=c)
    p = st["splits"][0] if st["splits"] else {}
    t.ok("Open in Split View: c beside the page on screen", p.get("tabs") == [a, c] and st["activeID"] == c, st["splits"])
    t.ok("…and next to it in the row", order(st).index(c) == order(st).index(a) + 1, order(st))
    st = sp("side", left=True); t.ok("⌃⌘←: the left page", st["activeID"] == a)
    st = sp("side", left=False); t.ok("⌃⌘→: the right page", st["activeID"] == c)
    sp("fraction", split=p["id"], fraction=0.3)
    st = sp("swap")
    q = st["splits"][0]
    t.ok("swap: order reversed in the pair", q["tabs"] == [c, a], q)
    t.ok("swap: sizes follow their pages", abs(q["sizes"][0] - 0.7) < 1e-9, q["sizes"])
    t.ok("swap: order reversed in the row", order(st).index(a) == order(st).index(c) + 1, order(st))
    t.ok("swap: focus stays on its page", st["activeID"] == c)
    st = sp("even"); t.ok("even out", st["splits"][0]["sizes"] == [0.5, 0.5])
    # close a page, then ⇧⌘T puts it back in its pair
    st = sp("close", id=c)
    t.ok("⌘W on a page: pair gone, the other page in front", not st["splits"] and st["activeID"] == a, (st["splits"], st["activeID"]))
    st = sp("reopen"); time.sleep(0.8); st = sp("state")
    back = [x["id"] for x in st["tabs"] if x["url"].endswith("/c")]
    t.ok("⇧⌘T: back into its pair, on its side", len(st["splits"]) == 1 and back and st["splits"][0]["tabs"] == [back[0], a], st["splits"])
    c = back[0]
    # empty page: start, fill with an open tab
    sp("select", id=d); st = sp("start")
    blank = st["splits"][-1]["right"]
    st = sp("fill", id=blank, **{"with": b})
    pr = [x for x in st["splits"] if d in x["tabs"]]
    t.ok("an empty page takes an open tab", pr and pr[0]["tabs"] == [d, b] and blank not in order(st) and st["activeID"] == b, (st["splits"], order(st)))
    t.ok("…next to its partner in the row", order(st).index(b) == order(st).index(d) + 1, order(st))
    # empty page: Esc cancels
    sp("detach", id=d); sp("select", id=d); st = sp("start")
    blank = st["splits"][-1]["right"]
    st = sp("dismiss")
    t.ok("Esc on an empty page cancels it", blank not in order(st) and not any(d in x["tabs"] for x in st["splits"]) and st["activeID"] == d, (st["splits"], st["activeID"]))
    # close both
    sp("select", id=a); n = len(order(sp("state")))
    st = sp("closeBoth")
    t.ok("Close Both closes the pair's two pages", a not in order(st) and c not in order(st) and len(order(st)) == n - 2, order(st))


def case_slice5a(t):
    """with the rest"""
    def order(st): return [x["id"] for x in st["tabs"]]
    setup(splitView=True, spaces=True); launch()
    m = page("mail"); a = page("apple-apple"); b = page("apple-apple-apple"); x = page("x")
    cmd({"do": "pin", "id": m})
    # ⌥⌘N on a pin: a copy of its page and an empty page; the pin stays
    sp("select", id=m); st = sp("start"); time.sleep(0.6); st = sp("state")
    p = st["splits"][-1]
    t.ok("⌥⌘N on a pin: the pin stays pinned, out of the pair", m in st["pins"] and m not in p["tabs"], (st["pins"], p))
    t.ok("…its page is in the pair as a tab of its own", url(st, p["tabs"][0]).endswith("/mail"), url(st, p["tabs"][0]))
    sp("dismiss")
    # dragging a tab onto a pin's page: a copy, pin untouched
    sp("select", id=m); st = sp("pair", id=x, **{"with": m}, side="right"); time.sleep(0.6); st = sp("state")
    p = [q for q in st["splits"] if x in q["tabs"]][0]
    t.ok("a tab onto a pin's page: pair with a copy, pin kept", m in st["pins"] and m not in p["tabs"] and url(st, p["tabs"][0]).endswith("/mail"), (st["pins"], p))
    copy = p["tabs"][0]
    # Close Other Tabs keeps the partner
    st = sp("closeOthers", id=x)
    t.ok("Close Other Tabs keeps the other page of the pair", x in order(st) and copy in order(st) and a not in order(st) and b not in order(st), order(st))
    # find keeps its needle across pages
    a = page("apple-apple"); b = page("apple-apple-apple")
    sp("select", id=a); sp("pair", id=b, **{"with": a}, side="right"); sp("focus", id=a); time.sleep(0.8)
    r = cmd({"do": "find", "text": "apple"})
    t.ok("find in the left page", r["status"].endswith("of 2"), r)
    st = sp("focus", id=b); time.sleep(1.2); st = sp("state")
    t.ok("focus moves: find stays open with its words", st["finding"] and st["needle"] == "apple", (st["finding"], st["needle"]))
    t.ok("…and looks in the other page", st["findStatus"].endswith("of 3"), st["findStatus"])
    # moving a page to another space leaves its partner in front
    first = sp("state")["spaceID"]
    sp("space", spaceAction="new", name="Two"); time.sleep(1)
    other = [k for k in sp("rows")["rows"].keys() if k != first][0]
    sp("space", spaceAction="go", spaceID=first); time.sleep(1)
    sp("focus", id=b)
    st = sp("moveSpace", id=b, spaceID=other); time.sleep(0.8); st = sp("state")
    t.ok("a page moved to another Space: its partner is in front", st["activeID"] == a and b not in order(st), (st["activeID"], order(st)))


def case_slice5b(t):
    """questions over one page"""
    def ev(id, js): return cmd({"do": "eval", "id": id, "js": js}).get("value")
    setup(splitView=True); launch()
    a = page("a"); b = page("b")
    sp("pair", id=b, **{"with": a}, side="right"); sp("focus", id=a); time.sleep(0.8)
    ev(b, "setTimeout(function(){ window.__r = confirm('Leave this page?') }, 0); 1"); asked(b)
    st = sp("state"); q = st["questions"]
    t.ok("confirm from the other page: a card over it", len(q) == 1 and q[0]["tab"] == b and q[0]["kind"] == "confirm" and q[0]["message"] == "Leave this page?", q)
    t.ok("named for the site asking", q and q[0]["host"] == "127.0.0.1", q)
    t.ok("focus stays where it was", st["activeID"] == a)
    t.ok("not held for later, not a sheet", st["held"] == {}, st["held"])
    sp("answer", id=b, ok=True); time.sleep(0.4)
    t.ok("OK answers true, once", ev(b, "window.__r") is True and qs() == [])
    ev(b, "setTimeout(function(){ window.__r = prompt('Name?', 'x') }, 0); 1"); asked(b)
    t.ok("prompt: a card", qs() and qs()[0]["kind"] == "prompt")
    sp("answer", id=b, ok=True, text="hello"); time.sleep(0.4)
    t.ok("prompt answers what was typed", ev(b, "window.__r") == "hello")
    ev(b, "setTimeout(function(){ window.__r = prompt('Name?') }, 0); 1"); asked(b)
    sp("answer", id=b, ok=False); time.sleep(0.4)
    t.ok("prompt cancelled answers null", ev(b, "window.__r") is None)
    # a page asking again and again: one at a time, in order
    ev(b, "setTimeout(function(){ window.__n = 0; for (var i = 0; i < 3; i++) { alert('again ' + i); window.__n++ } }, 0); 1")
    seen = []
    for i in range(3):
        q = asked(b); seen.append((len(q), q[0]["message"] if q else None))
        sp("answer", id=b, ok=True); time.sleep(0.5)
    t.ok("asked again and again: one card at a time, in order", seen == [(1, "again 0"), (1, "again 1"), (1, "again 2")], seen)
    t.ok("…every one answered", ev(b, "window.__n") == 3)
    # the other page keeps working meanwhile
    ev(b, "setTimeout(function(){ confirm('Still there?') }, 0); 1"); asked(b)
    t.ok("the other page answers while one waits", ev(a, "1 + 1") == 2)
    # closed while asking: answered as dismissed, no hang
    st = sp("close", id=b); time.sleep(0.4)
    t.ok("page closed while asking: its card goes", qs() == [])
    b = page("b2"); sp("pair", id=b, **{"with": a}, side="right"); time.sleep(0.8)
    ev(b, "setTimeout(function(){ confirm('Leave?') }, 0); 1"); asked(b)
    sp("go", id=b, url=f"{BASE}/elsewhere") if False else cmd({"do": "go", "id": b, "url": f"{BASE}/elsewhere"}); time.sleep(1.5)
    t.ok("page gone elsewhere: its card goes", qs() == [], qs())
    ev(b, "setTimeout(function(){ confirm('Leave?') }, 0); 1"); asked(b)
    sp("enabled", on=False); time.sleep(0.4)
    t.ok("Split View off: the card is answered as dismissed", qs() == [])
    sp("enabled", on=True); sp("select", id=a); time.sleep(0.5)
    # a frame from another site is named as itself
    c = page("asker"); sp("pair", id=c, **{"with": a}, side="right"); sp("focus", id=a)
    q = asked(c)
    t.ok("a frame from another site is named as itself", q and q[0]["tab"] == c and q[0]["host"] == "localhost", q)
    if q: sp("answer", id=c, ok=True)
    # one page alone: the sheet path as before (a test run writes it down)
    sp("detach", id=a); sp("select", id=a); time.sleep(0.5)
    ev(a, "setTimeout(function(){ alert('alone') }, 0); 1"); time.sleep(1.5)
    t.ok("a page alone: no card, the usual way", qs() == [])


def case_slice6(t):
    """moving"""
    setup(splitView=True); launch()
    a = page("a"); b = page("b"); sp("select", id=a); time.sleep(0.6)
    full = [f for f in sp("state")["paneFrames"] if f["id"] == a][0]["width"]
    sp("pair", id=b, **{"with": a}, side="right")
    s = sample()
    moving = [m for m in s if m]
    t.ok("enter: the page on screen moves as a picture", bool(moving), s[:3])
    if moving:
        m = moving[0][0]
        t.ok("…from full width to its half", abs(m["from"][2] - full) < 1 and abs(m["to"][2] - (full - 7) / 2) < 1, m)
        mids = [x[0]["now"][2] for x in moving if x]
        t.ok("…through the widths between", any(m["to"][2] + 5 < w < m["from"][2] - 5 for w in mids), mids)
    time.sleep(0.8)
    t.ok("the pictures are gone once it is over", sp("motion")["motion"] == [])
    st = sp("state"); f = {x["id"]: x for x in st["paneFrames"]}
    t.ok("pages laid out at their new size", abs(f[a]["width"] - (full - 7) / 2) < 1)
    sp("swap"); s = sample(8); moving = [m for m in s if m]
    t.ok("swap: both pictures travel", moving and len(moving[0]) == 2, s[:2])
    time.sleep(0.8)
    sp("fraction", split=st["splits"][0]["id"], fraction=0.3); time.sleep(0.8)
    sp("even"); s = sample(8); moving = [m for m in s if m]
    t.ok("even out: the pages move to even halves", moving and all(abs(x["to"][2] - (full - 7) / 2) < 1 for x in moving[0]), s[:2])
    time.sleep(0.8)
    sp("close", id=b); s = sample(8); moving = [m for m in s if m]
    t.ok("leave: the other grows to full width", moving and any(abs(x["to"][2] - full) < 1 for x in moving[0]), s[:2])
    time.sleep(0.8)
    c = page("c"); sp("select", id=a)
    s = sample(4)
    t.ok("a tab switch is a cut", all(m == [] for m in s), s)



def case_peek(t):
    """a peek kept beside"""
    setup(splitView=True); launch()
    a = page("docs"); sp("select", id=a); time.sleep(0.6)
    cmd({"do": "peek", "url": f"{BASE}/reference"}); time.sleep(1)
    cmd({"do": "ui", "peeklink": "beside"}); time.sleep(0.8)
    st = sp("state")
    kept = [x["id"] for x in st["tabs"] if x["url"].endswith("/reference")]
    t.ok("a peek kept beside: in a pair with the page it came from", kept and st["splits"] and st["splits"][0]["tabs"] == [a, kept[0]], (st["splits"], kept))
    t.ok("…and the kept page has the keys", kept and st["activeID"] == kept[0])
    sp("enabled", on=False)
    cmd({"do": "peek", "url": f"{BASE}/other"}); time.sleep(1)
    cmd({"do": "ui", "peeklink": "beside"}); time.sleep(0.8)
    st = sp("state")
    other = [x["id"] for x in st["tabs"] if x["url"].endswith("/other")]
    t.ok("Split View off: kept as a tab, as before", other and st["activeID"] == other[0] and len(st["splits"]) == 1, (st["splits"], other))


def main():
    t = T()
    for case in [case_slice1, case_slice1b, case_slice2, case_slice3, case_slice4, case_slice5a, case_slice5b, case_slice6, case_peek]:
        print(f"— {case.__doc__}")
        try:
            case(t)
        except Exception as error:
            t.ok(f"{case.__name__} ran to the end", False, error)
        finally:
            finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
