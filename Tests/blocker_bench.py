#!/usr/bin/env python3
"""What an ad blocker costs a page, measured in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/blocker_bench.py`. Up to
five setups, each in a fresh launch of the same world
(SEARCH_PROBE=blocker-bench):

    none         Shield off, no extensions: the page as it comes
    shield       Search's own content rule list (Shield.swift), no extensions
    ubol         uBlock Origin Lite from the Chrome Web Store, as Search runs
                 it, with the shim (ExtensionShims.swift) in its worker and pages
    ubol-bare    the same uBOL with the shim's scripts emptied and its worker's
                 copy cut out: what WebKit alone makes of the Chrome build
    ubol-safari  uBOL's Safari build, unpacked, with the shim cut out the same
                 way: the package uBOL makes for WebKit, as close to how Safari
                 runs it as Search can load it. Only with --safari PATH, the
                 folder `tools/make-mv3.sh safari` in gorhill/uBlock builds.

Each uBOL runs as installed: <all_urls> granted, so in its Optimal mode, with
its cosmetic and scriptlet content scripts registered. What it has registered
is printed once per setup, so a setup where it quietly did less shows as such.
Only one extension is switched on at a time.

Search always puts the shim in at install, so the two stripped setups first
ran once with it; what uBOL registered then (content scripts, storage) is
still there when they run without.

Two differences from Safari itself remain for ubol-safari: its pages are
served from chrome-extension://, which uBOL reads as Chromium where it checks
(webextFlavor in ext.js), and it runs in Search's controller rather than
Safari's.

The setups take turns within each round, in an order that rotates, so a slow
minute on the network lands on all of them rather than on one. Before the
first round every site is visited once, unmeasured, so whichever setup goes
first doesn't pay for an empty HTTP cache. Each page is then loaded LOADS
times per setup per round, in a new tab each time; medians are printed.

For each load:
    wall      ms from `open` to the tab done loading, as the bench sees it
    DCL/load  the page's own navigation timing
    reqs      requests that reached the network SETTLE seconds after load
              (ads load late); a request a content blocker stops never gets a
              resource-timing entry
    ad reqs   how many of those went to ad and tracking hosts (ADS below)
    RSS       resident memory of the page's WebContent process, in MB
A load that never finished within LIMIT seconds is counted under timeouts
and left out of the timing medians; its request counts still go in.

For each launch: ms until the probe answered, then until every extension
switched on had loaded, then until the first ad request was refused. Then,
asking again in a new tab each time until HOLD seconds after the launch,
when the last one got through anyway, and how many did: blocking that starts
and then lapses while WebKit compiles an extension's rules again (uBOL sets
its session rules again at each launch).

Then, apart from the browser: how long JavaScriptCore takes to compile the
shim and the passkey patch as uBOL's copy carries them. That is the floor of
what the shim adds each time uBOL's worker wakes (the shim) and each time one
of its main-world scriptlets goes into a frame (the passkey patch).

    python3 Tests/blocker_bench.py [--rounds N] [--loads N] [--sites URL,URL…]
                                   [--setups none,shield,ubol,ubol-bare,ubol-safari]
                                   [--safari PATH] [--json PATH]

uBOL is downloaded from the Chrome Web Store once per run, into this world
only. The world is removed afterwards. Real sites, so real noise: compare
setups within one run, not across runs. CNN was left out: in a hidden probe
it keeps loading on some visits with no blocker at all (3 or 4 in 6).
"""

import argparse
import json
import os
import shutil
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = str(ROOT / "build" / "Search.app")
W = "blocker-bench"
HOME = os.path.expanduser("~")
SUPPORT = f"{HOME}/Library/Application Support/Search ({W})"
SUITE = f"com.officecommun.search.test.{W}"
SOCK = f"{SUPPORT}/bench.sock"
UBOL = "ddkjiahejlhfcafbddmgiahcphecmpfh"
EXT = f"{SUPPORT}/Extensions/{UBOL}"

SITES = [
    "https://www.independent.co.uk/",
    "https://www.dailymail.co.uk/home/index.html",
    "https://www.theguardian.com/international",
    "https://www.speedtest.net/",
]
SETUPS = ["none", "shield", "ubol", "ubol-bare", "ubol-safari"]
# Each extension setup: which install it runs, and which copy of its folder.
KINDS = {"ubol": ("store", "shim"), "ubol-bare": ("store", "bare"), "ubol-safari": ("safari", "safari")}
SETTLE = 6
LIMIT = 20
HOLD = 15

# Hosts whose only job is ads or tracking, as these four sites call them: a
# request to one that reached the network is one a blocker let through.
ADS = "|".join([
    "doubleclick", "googlesyndication", "googletagservices", "googleadservices", "googletagmanager",
    "google-analytics", "analytics\\.google", "adtrafficquality", "imasdk", "amazon-adsystem", "adnxs",
    "taboola", "outbrain", "criteo", "pubmatic", "rubiconproject", "openx", "adsrvr", "moatads",
    "scorecardresearch", "facebook\\.net", "chartbeat", "quantserve", "casalemedia", "indexww", "teads",
    "smartadserver", "bidswitch", "33across", "sharethrough", "yieldmo", "3lift", "triplelift",
    "media\\.net", "adform", "permutive", "krxd", "fwmrm", "adsafeprotected", "intentiq", "kargo",
    "ml314", "eyeota", "demdex", "stackadapt", "liadm", "crwdcntrl", "optable", "panxo", "bounceexchange",
    "dotmetrics", "creativecdn", "yellowblue", "optidigital", "confiant", "durationmedia", "fastclick",
    "mediamelon", "brightline", "litix", "researchnow", "pix\\.pub", "hadronid", "idsequoia", "ltmsphrcl",
    "sail-horizon", "sail-track", "sail-personalize", "securedvisit", "rkdms", "wknd\\.ai",
    "webcontentassessor", "go-mpulse", "visualwebsiteoptimizer", "optimizely", "trackcmp",
])

MEASURE = """(() => {
  const n = performance.getEntriesByType('navigation')[0] || {};
  const r = performance.getEntriesByType('resource');
  const ads = new RegExp(%s);
  let hits = 0;
  for (const e of r) {
    let h = ''; try { h = new URL(e.name).hostname; } catch (x) {}
    if (ads.test(h)) hits++;
  }
  return JSON.stringify({ dcl: Math.round(n.domContentLoadedEventEnd || 0), load: Math.round(n.loadEventEnd || 0),
    requests: r.length, ads: hits });
})()""" % json.dumps(ADS)

# What uBOL has set up, read from one of its own pages. `eval` hands back
# only what is there when it returns, so the answer is left on the page.
UBOL_STATE = """(async () => { try { window.__state = JSON.stringify({
  scripts: (await chrome.scripting.getRegisteredContentScripts()).length,
  sessionRules: (await chrome.declarativeNetRequest.getSessionRules()).length,
  dynamicRules: (await chrome.declarativeNetRequest.getDynamicRules()).length,
  rulesets: (await chrome.declarativeNetRequest.getEnabledRulesets()).length,
}); } catch (e) { window.__state = JSON.stringify({ error: String(e) }); } })(); 0"""


# MARK: - the probe, as the other probe tests start and stop it

started = set()
def running(): return set(subprocess.run(["pgrep", "-f", APP + "/Contents/MacOS"], capture_output=True, text=True).stdout.split())
def holding(): return set(subprocess.run(["lsof", "-t", "--", SOCK], capture_output=True, text=True).stdout.split()) if os.path.exists(SOCK) else set()
def pids(): return sorted((started & running()) | (holding() & running()))

def wipe():
    subprocess.run(["rm", "-rf", SUPPORT]); subprocess.run(["defaults", "delete", SUITE], capture_output=True)

def main_checkout():
    git = lambda *a: subprocess.run(["git", "-C", str(ROOT), "rev-parse", *a], capture_output=True, text=True).stdout.strip()
    return git("--git-dir") != "" and Path(git("--absolute-git-dir")) == Path(ROOT, git("--git-common-dir")).resolve()

def defaults(key, kind, value):
    subprocess.run(["defaults", "write", SUITE, key, kind, value])

def cmd(req, timeout=60):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as c:
        c.settimeout(timeout); c.connect(SOCK); c.sendall(json.dumps(req).encode() + b"\n")
        data = b""
        while True:
            ch = c.recv(65536)
            if not ch: break
            data += ch
    a = json.loads(data.split(b"\n", 1)[0] or b"{}")
    if "error" in a: raise RuntimeError(f"{req.get('do')}: {a['error']}")
    return a

def launch():
    """Starts the probe hidden → seconds until its socket answered."""
    if os.path.exists(SOCK): os.remove(SOCK)
    before = running()
    t0 = time.monotonic()
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={W}", APP])
    for _ in range(300):
        if os.path.exists(SOCK):
            try: cmd({"do": "tabs"}, timeout=5); break
            except Exception: pass
        time.sleep(0.05)
    else:
        sys.exit("the probe never opened its socket")
    up = time.monotonic() - t0
    started.update((running() - before) & holding())
    return up

def quit():
    try: cmd({"do": "quit"}, timeout=5)
    except Exception: pass
    for _ in range(50):
        if not pids(): break
        time.sleep(0.2)
    for p in pids(): subprocess.run(["kill", p])
    time.sleep(0.5)

def extensions():
    return cmd({"do": "extensions"})["extensions"]

def until_loaded(limit=30):
    """Seconds until every extension switched on has loaded, or None."""
    t0 = time.monotonic()
    while time.monotonic() - t0 < limit:
        on = [e for e in extensions() if e["enabled"]]
        if all(e["loaded"] for e in on): return time.monotonic() - t0
        time.sleep(0.05)
    return None


# MARK: - uBOL, with the shim and without

def install_ubol():
    cmd({"do": "ext-answer", "answer": "yes"})
    cmd({"do": "ext-add", "id": UBOL, "yes": True})
    for _ in range(600):
        found = [e for e in extensions() if e["id"] == UBOL]
        if found and found[0]["loaded"]: return found[0]
        time.sleep(0.1)
    sys.exit("uBOL didn't install within a minute: " + json.dumps(extensions()))

def install_folder(path):
    """An unpacked extension, as Settings › Extensions takes one → its entry
    (Search gives it a local-… id of its own)."""
    before = {e["id"] for e in extensions()}
    cmd({"do": "ext-answer", "answer": "yes"})
    cmd({"do": "ext-folder", "path": str(path), "yes": True})
    for _ in range(600):
        new = [e for e in extensions() if e["id"] not in before]
        if new and new[0]["loaded"]: return new[0]
        time.sleep(0.1)
    sys.exit(f"{path} didn't install within a minute: " + json.dumps(extensions()))

FLAVOR = "if ( extURL.startsWith('safari-web-extension:') ) { return 'safari'; }"

def as_in_safari(folder):
    """uBOL tells Safari by its pages' scheme, safari-web-extension://; in
    Search they are chrome-extension://, and the Safari build would take its
    Chromium branches (strict blocking on, no CSS in subframes, no procedural
    cosmetics). Pinned to what Safari would answer."""
    ext = Path(folder, "js", "ext.js")
    source = ext.read_text()
    if FLAVOR not in source: sys.exit(f"uBOL's flavour check isn't where it was in {ext}; look before benching")
    ext.write_text(source.replace(FLAVOR, "return 'safari'; // blocker_bench: as Safari answers"))

MARKER = "/* Search: Chrome APIs WebKit lacks, filled in (ExtensionShims.swift) */"
ENDER = "/* Search: end of shim */"

def strip(folder):
    """The shim taken out of a prepared extension without Search noticing:
    its two scripts emptied (every reference to them now loads nothing), and
    a classic worker's inlined copy cut out. The stamp stays, so Search's
    prepare() takes the folder as done and leaves it alone."""
    folder = Path(folder)
    for name in ("search-shim.js", "search-passkeys.js"):
        if (folder / name).exists(): (folder / name).write_text("")
    manifest = json.loads((folder / "manifest.json").read_text())
    worker = (manifest.get("background") or {}).get("service_worker")
    if worker:
        path = folder / worker.lstrip("/")
        source = path.read_text()
        if source.startswith(MARKER) and ENDER in source:
            path.write_text(source.split(ENDER, 1)[1].lstrip("\n"))

def installed_folder(id):
    return Path(SUPPORT, "Extensions", id)

def use(folder, id=UBOL):
    shutil.rmtree(installed_folder(id), ignore_errors=True)
    shutil.copytree(folder, installed_folder(id), symlinks=True)

def enable_only(ids):
    """Switches extensions on and off between launches, in the list Search
    reads at launch (it isn't running to write over it)."""
    path = Path(SUPPORT, "Extensions", "installed.json")
    items = json.loads(path.read_text())
    for item in items: item["enabled"] = item["id"] in ids
    path.write_text(json.dumps(items))

def set_ubol(enabled):
    enable_only({UBOL} if enabled else set())

def ubol_state(id=UBOL):
    try:
        tab = cmd({"do": "ext-page", "id": id, "path": "dashboard.html"})["id"][:8]
        cmd({"do": "wait", "id": tab, "seconds": 10})
        cmd({"do": "eval", "id": tab, "js": UBOL_STATE})
        for _ in range(40):
            value = cmd({"do": "eval", "id": tab, "js": "window.__state || ''"}).get("value")
            if value: break
            time.sleep(0.1)
        cmd({"do": "close", "id": tab})
        return json.loads(value or '{"error": "no answer"}')
    except Exception as error:
        return {"error": str(error)}


# MARK: - one load

def rss_mb(pid):
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return int(out) // 1024 if out.isdigit() else None

def load(url, measure=True):
    t0 = time.monotonic()
    tab = cmd({"do": "open", "url": url})["id"][:8]
    done = cmd({"do": "wait", "id": tab, "seconds": LIMIT}, timeout=LIMIT + 15)
    wall = time.monotonic() - t0 - 0.25   # the bench's own beat after loading
    page = {}
    if measure:
        time.sleep(SETTLE)
        try: page = json.loads(cmd({"do": "eval", "id": tab, "js": MEASURE})["value"])
        except Exception as error: page = {"error": str(error)}
        pid = next((t.get("process", 0) for t in cmd({"do": "tabs"})["tabs"] if t["id"].startswith(tab)), 0)
        page.update(wall=round(wall * 1000), timeout=bool(done.get("timeout")), rss=rss_mb(pid) if pid else None)
    cmd({"do": "close", "id": tab})
    time.sleep(0.5)
    return page


# MARK: - protected yet?

# An extension reads as loaded before WebKit has finished compiling its rules
# into a content rule list, and a page loaded in between gets through
# unblocked. So after each launch, before anything is measured: a request to
# an ad exchange (AppNexus) from a blank page on this Mac, in a new tab each
# try (a rule list reaches the views made after it's ready), until one is
# refused. Its host is blocked outright, for every kind of request, by
# EasyList, uBlock filters and Shield alike; an address uBO answers with a
# stand-in script instead (adsbygoogle.js, gpt.js) would load either way and
# say nothing. How long that took is reported too: it is how long a page is
# unprotected after Search opens.
PROBE_AD = "https://secure.adnxs.com/px"
TRY = ("(() => { window.__b = ''; fetch(%s + '?' + Math.random(), { mode: 'no-cors', cache: 'no-store' })"
       ".then(() => { window.__b = 'through'; }, () => { window.__b = 'blocked'; }); return 0; })()" % json.dumps(PROBE_AD))

class Blank(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"<!doctype html><title>blank</title>"
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass

blank = None

def ask():
    """'blocked' or 'through', for an ad request from a new tab."""
    global blank
    if blank is None:
        server = ThreadingHTTPServer(("127.0.0.1", 0), Blank)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        blank = f"http://127.0.0.1:{server.server_port}/"
    tab = cmd({"do": "open", "url": blank})["id"][:8]
    cmd({"do": "wait", "id": tab, "seconds": 5})
    cmd({"do": "eval", "id": tab, "js": TRY})
    said = ""
    for _ in range(50):
        said = cmd({"do": "eval", "id": tab, "js": "window.__b"}).get("value") or ""
        if said: break
        time.sleep(0.1)
    cmd({"do": "close", "id": tab})
    return said

def until_blocking(since, limit=90):
    """Seconds from `since` until an ad request is refused, or None."""
    while time.monotonic() - since < limit:
        if ask() == "blocked": return time.monotonic() - since
        time.sleep(0.25)
    return None

def lapses(since, hold=HOLD):
    """After blocking started: seconds from `since` to the last ad request
    let through before `hold`, or None, and how many were."""
    last, through = None, 0
    while time.monotonic() - since < hold:
        if ask() == "through": last, through = time.monotonic() - since, through + 1
        time.sleep(0.25)
    return last, through


# MARK: - the shim, compiled on its own

def parse_cost(folder, runs=30):
    """ms for JavaScriptCore to compile each file, averaged over `runs`
    (Date.now() is whole milliseconds; one compile can be less). Each copy
    ends differently, so none is served from JSC's cache of a source it has
    already seen."""
    out = {}
    for name in ("search-shim.js", "search-passkeys.js"):
        source = Path(folder, name).read_text()
        js = ("var src = %s, a = Date.now();"
              "for (var i = 0; i < %d; i++) new Function(src + '\\n//' + i);"
              "JSON.stringify({ lines: src.split('\\n').length, kb: Math.round(src.length / 1024),"
              " ms: Math.round((Date.now() - a) / %d * 100) / 100 });"
              % (json.dumps(source), runs, runs))
        result = subprocess.run(["osascript", "-l", "JavaScript", "-e", js], capture_output=True, text=True)
        out[name] = json.loads(result.stdout) if result.returncode == 0 else {"error": result.stderr.strip()}
    return out


# MARK: - the run

def main():
    parser = argparse.ArgumentParser(description="Ad blockers' cost to a page, in a hidden probe.")
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--loads", type=int, default=2)
    parser.add_argument("--sites", default=",".join(SITES))
    parser.add_argument("--setups")
    parser.add_argument("--safari", help="uBOL's Safari build, unpacked (dist/build/uBOLite.safari)")
    parser.add_argument("--json")
    args = parser.parse_args()
    sites = [s for s in args.sites.split(",") if s]
    default = [s for s in SETUPS if s != "ubol-safari" or args.safari]
    setups = [s for s in args.setups.split(",") if s] if args.setups else default
    unknown = set(setups) - set(SETUPS)
    if unknown: sys.exit(f"unknown setups: {', '.join(sorted(unknown))}")
    if "ubol-safari" in setups and not (args.safari and Path(args.safari, "manifest.json").exists()):
        sys.exit("ubol-safari needs --safari PATH, the unpacked Safari build of uBOL")

    if not Path(APP).exists(): sys.exit(f"no {APP} — ./build.sh first")
    if main_checkout() and running():
        sys.exit(f"{APP} is running from the main checkout. Run the bench from a worktree.")

    for p in pids(): subprocess.run(["kill", p])
    wipe()
    for key in ("bench", "welcomed"): defaults(key, "-bool", "true")
    defaults("shield", "-bool", "false")

    keep = Path(tempfile.mkdtemp(prefix="blocker-bench-"))
    results = {s: {site: [] for site in sites} for s in setups}
    launches = {s: [] for s in setups}
    states = {}
    ids = {}   # "store" / "safari" → the id Search gave it
    kinds = {KINDS[s][0] for s in setups if s in KINDS}
    try:
        launch()
        if "store" in kinds:
            print("installing uBlock Origin Lite from the Chrome Web Store…")
            found = install_ubol()
            ids["store"] = found["id"]
            print(f"  uBOL {found['version']} loaded; errors: {found['errors'] or 'none'}")
        if "safari" in kinds:
            print(f"installing uBOL's Safari build from {args.safari}…")
            source = keep / "safari-source"
            shutil.copytree(args.safari, source, symlinks=True)
            as_in_safari(source)
            found = install_folder(source)
            ids["safari"] = found["id"]
            print(f"  uBOL (Safari) {found['version']} loaded as {found['id']}; errors: {found['errors'] or 'none'}")
        # Off through the app while it runs: it writes installed.json
        # itself, and would write over an edit made underneath it.
        for id in ids.values():
            cmd({"do": "ext-enable", "id": id, "on": False})
        time.sleep(0.5)
        print("warming the HTTP cache…")
        for site in sites: load(site, measure=False)
        quit()
        if "store" in kinds:
            shutil.copytree(installed_folder(UBOL), keep / "shim", symlinks=True)
            shutil.copytree(installed_folder(UBOL), keep / "bare", symlinks=True)
            strip(keep / "bare")
        if "safari" in kinds:
            shutil.copytree(installed_folder(ids["safari"]), keep / "safari", symlinks=True)
            strip(keep / "safari")

        for round in range(args.rounds):
            order = setups[round % len(setups):] + setups[:round % len(setups)]
            for setup in order:
                defaults("shield", "-bool", "true" if setup == "shield" else "false")
                on = None
                if setup in KINDS:
                    kind, copy = KINDS[setup]
                    on = ids[kind]
                    use(keep / copy, on)
                if ids:
                    enable_only({on} if on else set())
                    # Search clears registered workers at launch when this is
                    # gone: the copy WebKit kept can't be the other setup's.
                    subprocess.run(["defaults", "delete", SUITE, "extensions.workers"], capture_output=True)
                since = time.monotonic()
                up = launch()
                ready = until_loaded()
                blocking = until_blocking(since) if setup != "none" else None
                if setup != "none" and blocking is None:
                    print(f"  {setup}: nothing blocked within 90 s of launch; measuring anyway")
                last, through = lapses(since) if blocking is not None else (None, 0)
                launches[setup].append({"socket": ms(up), "extensions": ms(ready), "blocking": ms(blocking),
                                        "last_through": ms(last), "through": through})
                for site in sites:
                    for _ in range(args.loads):
                        results[setup][site].append(load(site))
                if on and setup not in states:
                    states[setup] = ubol_state(on)
                print(f"round {round + 1}/{args.rounds}: {setup} done")
                quit()

        parse = parse_cost(keep / "shim") if "store" in kinds else {}
    finally:
        quit(); wipe(); shutil.rmtree(keep, ignore_errors=True)

    report(results, launches, states, parse, sites, setups)
    if args.json:
        Path(args.json).write_text(json.dumps({"results": results, "launches": launches, "ubol": states, "parse": parse}, indent=2))
        print(f"\nraw numbers: {args.json}")

def ms(seconds):
    return None if seconds is None else round(seconds * 1000)

def median(values):
    values = [v for v in values if isinstance(v, (int, float))]
    return round(statistics.median(values)) if values else None

def report(results, launches, states, parse, sites, setups):
    timing = {"wall", "dcl", "load"}
    columns = ["wall", "dcl", "load", "requests", "ads", "rss"]
    heads = {"wall": "wall ms", "dcl": "DCL ms", "load": "load ms", "requests": "reqs", "ads": "ad reqs", "rss": "RSS MB"}
    for site in sites:
        print(f"\n{site}")
        print("  " + "setup".ljust(12) + "".join(heads[c].rjust(9) for c in columns) + "  timeouts")
        for setup in setups:
            loads = results[setup][site]
            finished = [l for l in loads if not l.get("timeout")]
            row = [median([l.get(c) for l in (finished if c in timing else loads)]) for c in columns]
            timeouts = sum(1 for l in loads if l.get("timeout"))
            print("  " + setup.ljust(12) + "".join(("-" if v is None else str(v)).rjust(9) for v in row) + f"  {timeouts}/{len(loads)}")
    print("\nlaunch (median ms from opening the app): probe answering, extensions loaded, first ad request refused;")
    print(f"then each launch's last ad request let through within {HOLD} s, after blocking had started, and how many were")
    for setup in setups:
        row = launches[setup]
        socket_up = median([l["socket"] for l in row])
        loaded = median([l["extensions"] for l in row])
        blocked = median([l["blocking"] for l in row])
        never = sum(1 for l in row if l["blocking"] is None) if setup != "none" else 0
        print(f"  {setup.ljust(12)} {socket_up}  +{loaded}  " + ("-" if setup == "none" else f"{blocked}")
              + (f"  (never, {never}/{len(row)})" if never else ""))
        if setup != "none":
            print("  " + " " * 12 + " " + ", ".join("-" if l.get("last_through") is None else f"{l['last_through']} ({l['through']})" for l in row))
    for setup, state in states.items():
        print(f"\n{setup}: uBOL had " + (state["error"] if "error" in state else
              f"{state['rulesets']} rulesets, {state['sessionRules']} session rules, "
              f"{state['dynamicRules']} dynamic rules, {state['scripts']} content scripts registered"))
    if parse:
        print("\ncompile alone, in JavaScriptCore (mean of 30)")
        for name, p in parse.items():
            print(f"  {name}: " + (f"{p['lines']} lines, {p['kb']} KB, {p['ms']} ms" if "ms" in p else p.get("error", "?")))

if __name__ == "__main__":
    main()
