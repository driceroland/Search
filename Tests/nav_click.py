#!/usr/bin/env python3
"""A followed link, a sent form and a page's own pushState, timed against the
same address typed into the field, and what each costs the window (idea 1327).

Build first (`./build.sh`), then `python3 Tests/nav_click.py [ROUNDS]`. A
hidden probe opens a local page in the tab in front, then, interleaved, ROUNDS
times each:

  typed  the next page's address pasted into the address field and Return
  go     the same as the tab's own load (Tab.go), without the field
  link   element.click() on a link to it
  form   the click on a search form's button (a GET, as Amazon's search is)
  spa    a click the page answers itself with history.pushState and a new
         block of the page, as YouTube's links are

For the loads it prints, in ms, the median from the moment of the action to
the new page's load event (on the wall clock both share), and in "parts"
where that went: the new document's start after the action, then its
requestStart, responseStart, domInteractive and loadEventEnd. For spa, the
longest the page itself was kept from running over the next second, and
how long its click took. The pages carry frames of another origin, as
Amazon's do: each frame's navigation is answered on Search's main thread.

`--cost N`: N rounds of each kind with nothing else asked meanwhile, and the
main thread's CPU over the next 1.5 s against doing nothing (Bench "passes"),
with the window's views drawn again ("drawn", the bench's body counters).
`--tabs N`: N tabs asleep down the side, as a window in use has.
`--plain`: the same flows in a WKWebView of no app at all (Tests/NavPlain,
PLAIN_FLAGS there). `--sample PATH`: a Time Profiler trace (TEMPLATE=SwiftUI
for SwiftUI's) while links are followed. `--app PATH` runs another build
(1.0.21's, say) in the same world; `--env K=V` hands it a variable; `--json`
prints one line. Nothing is shown, nothing makes a sound.

26 Nov, 150 tabs down the side: every page that finished loading drew the
whole window again for the History menu, column included; 1.0.21, main and
the fix compared in the commit that added this.
"""
import collections
import json
import os
import statistics
import sys
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
import threading

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("nav-click")
args = sys.argv[1:]
if "--app" in args:
    sv.APP = args[args.index("--app") + 1]
ROUNDS = int(args[0]) if args and args[0].isdigit() else 8
AS_JSON = "--json" in args
TABS = int(args[args.index("--tabs") + 1]) if "--tabs" in args else 0
COSTS = int(args[args.index("--cost") + 1]) if "--cost" in args else 0
SAMPLE = args[args.index("--sample") + 1] if "--sample" in args else None


def page(n, kind="p"):
    rows = "".join(f"<li class=r><a href='/item/{i}'>Result {n}.{i}</a> <span>some words about it</span></li>" for i in range(400))
    frames = "".join(f"<iframe src='{OTHER}/frame/{i}' width=120 height=60></iframe>" for i in range(6))
    return f"""<!doctype html><meta charset=utf-8><title>{kind} {n}</title>
<script>
addEventListener('load', () => setTimeout(() => {{ window.__loaded = Date.now() }}, 0));
</script>
<a id=next href='/p/{n + 1}'>next</a>
<form id=f action='/s'><input name=q value='shoes {n}'><button id=b>Go</button></form>
<a id=spa href='/p/{n}?v=1'>spa</a>
<div id=main><ul>{rows}</ul></div>{frames}
<script>
let spaN = 0;
document.getElementById('spa').addEventListener('click', e => {{
  e.preventDefault();
  spaN++;
  history.pushState({{}}, '', '/p/{n}?v=' + spaN);
  document.title = 'spa {n}.' + spaN;
  const ul = document.createElement('ul');
  for (let i = 0; i < 1500; i++) {{
    const li = document.createElement('li');
    li.innerHTML = "<a href='/watch/" + spaN + "/" + i + "'>comment " + i + "</a> <img width=1 height=1>";
    ul.appendChild(li);
  }}
  const main = document.getElementById('main');
  main.replaceChildren(ul);
}});
</script>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        p = self.path
        if p.startswith("/frame/"):
            body = "<!doctype html><title>frame</title><p>ad<form><input name=x></form>"
        elif p.startswith("/s"):
            body = page(int(time.time() * 1000) % 100000, "s")
        elif p.startswith("/p/"):
            body = page(int(p[3:].split("?")[0]))
        else:
            body = "<!doctype html><title>x</title>"
        b = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(b)

    def log_message(self, *a):
        pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"
OTHER = f"http://localhost:{srv.server_port}"


def active():
    return next(t for t in sv.cmd({"do": "tabs"})["tabs"] if t["active"])["id"]


def ev(tab, js):
    try:
        return sv.cmd({"do": "eval", "id": tab, "js": js}).get("value")
    except Exception:
        return None


def landed(tab, path, since, within=15):
    """The load event of the page at `path`, in ms after `since`."""
    until = time.time() + within
    while time.time() < until:
        v = ev(tab, "JSON.stringify([location.pathname + location.search, window.__loaded || 0, performance.timeOrigin, "
                    "(e => [e.requestStart, e.responseStart, e.domInteractive, e.loadEventEnd])(performance.getEntriesByType('navigation')[0])])")
        if v:
            where, at, origin, marks = json.loads(v)
            if where.startswith(path) and at:
                PARTS.setdefault(KIND[0], []).append([round(origin - since, 1)] + [round(m, 1) for m in marks])
                return at - since
        time.sleep(0.02)
    raise RuntimeError(f"no load of {path}")


PARTS = {}
KIND = [""]


def typed(tab, n):
    KIND[0] = "typed"
    a = sv.cmd({"do": "field", "text": f"{BASE}/p/{n}", "go": True})
    # 1.0.21's bench didn't say when Return went: there, the tab's own load.
    if "submittedAt" not in a:
        return go(tab, n)
    return landed(tab, f"/p/{n}", a["submittedAt"])


def go(tab, n):
    KIND[0] = "go"
    t = time.time() * 1000
    sv.cmd({"do": "go", "id": tab, "url": f"{BASE}/p/{n}"})
    return landed(tab, f"/p/{n}", t)


def link(tab, n):
    KIND[0] = "link"
    t = ev(tab, "(() => { const t = Date.now(); document.getElementById('next').click(); return t })()")
    return landed(tab, f"/p/{n}", t)


def form(tab, n):
    KIND[0] = "form"
    t = ev(tab, "(() => { const t = Date.now(); document.getElementById('b').click(); return t })()")
    return landed(tab, "/s", t)


SPA = """(() => {
  window.__gaps = null;
  const t0 = performance.now();
  let last = t0, worst = 0;
  const ch = new MessageChannel();
  const tick = () => {
    const now = performance.now();
    worst = Math.max(worst, now - last); last = now;
    if (now - t0 < 1000) ch.port2.postMessage(0); else window.__gaps = worst;
  };
  document.getElementById('spa').click();
  const done = performance.now() - t0;
  last = performance.now();
  ch.port1.onmessage = tick;
  ch.port2.postMessage(0);
  window.__spaClick = done;
  return 1;
})()"""


def spa(tab):
    start = time.time()
    ev(tab, SPA)
    until = time.time() + 10
    while time.time() < until:
        v = ev(tab, "JSON.stringify([window.__gaps, window.__spaClick])")
        if v:
            gaps, click = json.loads(v)
            if gaps is not None:
                return {"worstGap": gaps, "click": click}
        time.sleep(0.05)
    raise RuntimeError("spa loop never finished")


def cost(tab, act, seconds=1.5):
    """Search's main thread after one action: the CPU its run loop spent in
    the next `seconds`, and how often the window (Browser) said it changed.
    Nothing else asks the app anything meanwhile."""
    got = {}
    def watch():
        got.update(sv.cmd({"do": "passes", "seconds": seconds}))
    th = threading.Thread(target=watch)
    th.start()
    time.sleep(0.15)
    act()
    th.join()
    drawn = collections.Counter()
    for p in got["passes"]:
        for k, v in p.items():
            if k not in ("at", "ms", "cpu"):
                drawn[k] += v
    DRAWN.append(drawn)
    return sum(p.get("cpu", 0) for p in got["passes"]), len(got["browserTold"]), got["tabsTold"]


DRAWN = []


def costs(tab, n, rounds):
    """Each kind of navigation's cost to the window, against doing nothing."""
    js = lambda code: (lambda: sv.cmd({"do": "eval", "id": tab, "js": code}))
    out = {k: [] for k in ("idle", "link", "form", "spa", "go")}
    told = {k: [] for k in out}
    bodies = {k: [] for k in out}
    for r in range(rounds):
        for kind in out:
            if kind == "idle":
                act = lambda: None
            elif kind == "link":
                n += 1
                act = js("document.getElementById('next').click()")
            elif kind == "form":
                act = js("document.getElementById('b').click()")
            elif kind == "spa":
                act = js("document.getElementById('spa').click()")
            else:
                n += 1
                act = (lambda m: lambda: sv.cmd({"do": "go", "id": tab, "url": f"{BASE}/p/{m}"}))(n)
            if kind == "spa":
                # From a /p page, as the link and the form leave one.
                n += 1
                go(tab, n)
            cpu, b, t = cost(tab, act)
            if r:
                out[kind].append(cpu)
                told[kind].append(b)
                bodies[kind].append(DRAWN[-1])
    idle = med(out["idle"])
    res = {k: round(med(v) - idle, 1) for k, v in out.items() if k != "idle"}
    res["idleMs"] = idle
    res["windowTold"] = {k: med(v) for k, v in told.items()}
    # The window's own views drawn again, by the bench's counters (the
    # window, its content, the column, the strip, the app's menus, rows),
    # each kind's median: counts, so a busy Mac doesn't blur them.
    res["drawn"] = {k: {name: med([d.get(name, 0) for d in v]) for name in sorted(set().union(*v))} for k, v in bodies.items() if v and k != "idle"}
    return res


def med(xs):
    return round(statistics.median(xs), 1)


def launch():
    """sv.launch, with `--env K=V` handed on to the app (an experiment's
    switches)."""
    import os
    import subprocess
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    env = ["--env", f"SEARCH_PROBE={sv.W}"]
    for i, a in enumerate(args):
        if a == "--env":
            env += ["--env", args[i + 1]]
    subprocess.run(["open", "-n", "-g", "-j", *env, sv.APP])
    for _ in range(150):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update((sv.running() - before) & sv.holding())


def world(n):
    """N tabs besides the one measured, asleep as a session brings them
    back, down the side: a window as it is used, not an empty one."""
    import os
    os.makedirs(sv.SUPPORT, exist_ok=True)
    tabs = [{"url": f"{OTHER}/frame/{i}", "title": f"Tab {i}"} for i in range(n)] + [{"url": f"{BASE}/p/0", "title": "p 0"}]
    json.dump({"tabs": tabs, "active": n}, open(f"{sv.SUPPORT}/session.json", "w"))


def main():
    sv.setup(sidebar=TABS > 0)
    if TABS:
        world(TABS)
    launch()
    tab = active()
    n = 0
    typed(tab, n)
    time.sleep(1)
    res = {"typed": [], "go": [], "link": [], "form": [], "spa": [], "spaClick": []}
    for r in range(ROUNDS + 1):
        n += 1
        a = typed(tab, n)
        n += 1
        g = go(tab, n)
        n += 1
        b = link(tab, n)
        c = form(tab, n)
        n += 1
        typed(tab, n)  # back on a /p page for the next round's link
        s = spa(tab)
        if r == 0:
            continue  # warm-up
        res["typed"].append(a)
        res["go"].append(g)
        res["link"].append(b)
        res["form"].append(c)
        res["spa"].append(s["worstGap"])
        res["spaClick"].append(s["click"])
    if COSTS:
        res["cost"] = costs(tab, n + 100, COSTS)
    if SAMPLE:
        # Search's main thread profiled (Time Profiler, into the .trace
        # named) while links are followed, nothing else asked meanwhile.
        import subprocess
        pid = sv.pids()[0]
        proc = subprocess.Popen(["xcrun", "xctrace", "record", "--template", os.environ.get("TEMPLATE", "Time Profiler"), "--attach", pid,
                                 "--time-limit", "40s", "--output", SAMPLE], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(4)
        for _ in range(20):
            n += 1
            cost(tab, lambda: sv.cmd({"do": "eval", "id": tab, "js": "document.getElementById('next').click()"}))
        proc.wait()
    sv.quit()
    cost_ = res.pop("cost", None)
    out = {k: med(v) for k, v in res.items()}
    if cost_:
        out["cost"] = cost_
    # Where the time went, medians: [start of the navigation in the new
    # document after the action, then requestStart, responseStart,
    # domInteractive, loadEventEnd after that start]
    out["parts"] = {k: [med([r[i] for r in v]) for i in range(5)] for k, v in PARTS.items()}
    out["app"] = sv.APP
    print(json.dumps(out) if AS_JSON else json.dumps(out, indent=1))


def plain():
    """The same flows in a plain WKWebView of no app at all."""
    import subprocess
    exe = sv.ROOT / "build" / "nav-plain"
    src = Path(__file__).resolve().parent / "NavPlain" / "main.swift"
    if not exe.exists() or exe.stat().st_mtime < src.stat().st_mtime:
        subprocess.run(["swiftc", "-O", str(src), "-o", str(exe)], check=True)
    out = subprocess.run([str(exe), BASE, str(ROUNDS)], capture_output=True, text=True, timeout=600).stdout.strip()
    print(out if AS_JSON else json.dumps(json.loads(out), indent=1))


if "--plain" in args:
    plain()
else:
    try:
        main()
    finally:
        sv.finish()
