#!/usr/bin/env python3
"""Real Web Store extensions left running for a while: does Search grow?

Build first (`./build.sh`), then

    python3 Tests/mem_extension_soak.py [--ext ID ...] [--minutes 90] [--every 120]
                                        [--sites] [--out FILE] [--detail DIR] [--mallocstack]

Ideas 1252 (Bitwarden: the app process at ~1.4 GB overnight, 136 MB with it
off) and 1338 (Grammarly + uBlock Origin: ~4 GB with one or two tabs).

A copy of build/Search.app under a bundle id of its own, in a world of its
own, started hidden (`open -n -g -j`) and hidden again every quarter second;
the run stops at once if a window of it is ever on a screen. The extensions
are installed from the Chrome Web Store (Crx.swift's CRX3 check, as for
anyone), never signed in to anything. Then a few live tabs kept awake
(`sleep.after` far away): local pages with a sign-in form whose page keeps
changing (SPA-like: DOM churn, title, pushState), and with --sites also the
public sign-in pages of Gmail, Messenger and GitHub (opened, never typed
into). No page plays media.

Every --every seconds: the physical footprint (Activity Monitor's Memory
column) of Search's own process and of each process it is responsible for,
one JSON line per sample. --detail keeps `footprint`, `vmmap --summary` and
`heap -s` of the app process at the start and the end. --mallocstack starts
the app with MallocStackLogging=lite, for `malloc_history`/`heap -addresses`.

--host exit|silent: a stand-in for Bitwarden's desktop app's native
messaging host in the world's own folder (Bitwarden asks for it every 10 s
while not connected); each sample then also counts the app's open files.
--quiet SECS: pages whose title changes only every SECS seconds instead of
the busy ones, so the extension's worker idles and is started again (each
sample says how many times, from the bench). --favicons: the busy pages
also redraw a counted favicon every 2 s, as mail and chat sites do.

No extension given: Bitwarden (nngceckbapebfimnlniiiahkandclblb).
The copy, its WebKit folders and the world are removed afterwards.
"""
import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mem_at_rest as mr  # noqa: E402  (its measuring tools)
import split_view as sv  # noqa: E402

BITWARDEN = "nngceckbapebfimnlniiiahkandclblb"
BUNDLE = "com.officecommun.search.memsoak"

CHURN = """<!doctype html><title>churn {n}</title>
<form id=f action="/login" method=post><input name=email type=email autocomplete=username>
<input name=password type=password autocomplete=current-password><button>Sign in</button></form>
<div id=feed></div>
<script>
const FAVICONS = {favicons};
let i = 0;
setInterval(() => {{
  i++;
  const feed = document.getElementById('feed');
  const row = document.createElement('div');
  row.innerHTML = '<a href="/m/' + i + '">message ' + i + '</a> <input placeholder="reply ' + i + '">';
  feed.prepend(row);
  while (feed.childElementCount > 40) feed.lastElementChild.remove();
  document.title = '(' + (i % 9) + ') churn {n}';
  history.replaceState(null, '', '/churn{n}?i=' + i);
  if (FAVICONS && i % 4 === 0) {{
    // A favicon with a count, as mail and chat sites draw theirs.
    const c = document.createElement('canvas'); c.width = c.height = 32;
    const g = c.getContext('2d'); g.fillStyle = 'hsl(' + (i * 7 % 360) + ',70%,45%)'; g.fillRect(0, 0, 32, 32);
    g.fillStyle = '#fff'; g.font = 'bold 20px sans-serif'; g.fillText(String(i % 100), 4, 24);
    let l = document.querySelector('link[rel=icon]');
    if (!l) {{ l = document.createElement('link'); l.rel = 'icon'; document.head.appendChild(l); }}
    l.href = c.toDataURL('image/png');
  }}
  if (i % 20 === 0) {{
    // A sign-in form that comes and goes, as SPAs do.
    const f = document.getElementById('f'); const g = f.cloneNode(true); f.replaceWith(g);
  }}
}}, 500);
</script>"""


# A page that is quiet most of the time, as a mail or chat tab at rest: its
# title changes every few tens of seconds, so an extension's worker hears of
# it, goes idle, is unloaded by WebKit (~30 s) and is started again.
QUIET = """<!doctype html><title>quiet {n}</title>
<form action="/login" method=post><input name=email type=email autocomplete=username>
<input name=password type=password autocomplete=current-password><button>Sign in</button></form>
<script>let i = 0; setInterval(() => {{ i++; document.title = '(' + i + ') quiet {n}'; }}, {every});</script>"""
QUIET_MS = 45000
FAVICONS = False


# A page to write in, as Grammarly checks: a long text with mistakes in a
# focused text area, its last sentence rewritten every few seconds (the
# text stays the same length: a page whose text grows grows by itself).
WRITE = """<!doctype html><title>write</title>
<textarea id=t style="width:90%;height:60vh" spellcheck=true>{text}</textarea>
<div contenteditable=true id=c style="border:1px solid #888;min-height:200px">{text}</div>
<script>
const t = document.getElementById('t'), c = document.getElementById('c');
t.focus(); let i = 0; const base = t.value;
setInterval(() => {{ i++; t.value = base + ' their is ' + i + ' mistake here';
  if (i % 3 === 0) {{ c.focus(); if (c.lastChild && c.childNodes.length > 1) c.lastChild.remove(); c.append(' an other sentense ' + i); t.focus(); }} }}, 3000);
</script>"""
TEXT = ("Me and him goes to the store yesterday, and we buyed alot of things wich we dont need. "
        "Their are many reasons why this happen, but irregardless of them, it's effect on us were large. ") * 30


class Pages(sv.H):
    def do_GET(self):
        if self.path.startswith("/write"):
            body = WRITE.format(text=TEXT).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path.startswith("/quiet"):
            n = "".join(c for c in self.path.split("?")[0] if c.isdigit()) or "0"
            body = QUIET.format(n=n, every=QUIET_MS).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path.startswith("/churn"):
            n = "".join(c for c in self.path.split("?")[0] if c.isdigit()) or "0"
            body = CHURN.format(n=n, favicons="true" if FAVICONS else "false").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        return super().do_GET()


# Bitwarden's desktop app registers a native messaging host for Chrome,
# com.8bit.bitwarden (its desktop_proxy). The extension's IPC transport asks
# for it every ten seconds while it isn't connected, signed in or not. A
# stand-in in the probe world's own folder (ExtensionNative reads it first in
# a test run): "exit" leaves at once, as the proxy does with the desktop app
# closed; "silent" stays and says nothing, so the extension lets go after 5 s.
HOSTS = {"exit": "#!/bin/sh\nexit 0\n", "silent": "#!/bin/sh\nexec cat > /dev/null\n"}


def native_host(mode, work, exts):
    program = work / f"host-{mode}.sh"
    program.write_text(HOSTS[mode])
    program.chmod(0o755)
    folder = Path(sv.SUPPORT, "NativeMessagingHosts")
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "com.8bit.bitwarden.json").write_text(json.dumps({
        "name": "com.8bit.bitwarden", "description": "probe stand-in", "path": str(program), "type": "stdio",
        "allowed_origins": [f"chrome-extension://{e}/" for e in exts]}))


def probe_copy(work, source=None):
    app = work / "Search.app"
    shutil.copytree(source or Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def start(env):
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    exe = os.path.join(sv.APP, "Contents/MacOS/Search")
    w = subprocess.Popen([mr.MEAS, "watch", exe, "30000"], stdout=subprocess.PIPE, text=True)
    time.sleep(0.05)
    extra = [a for e in env for a in ("--env", e)]
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={sv.W}", *extra, sv.APP])
    pid = keeper = None
    for line in w.stdout:
        if line.startswith("pid "):
            pid = int(line.split()[1])
            sv.started.add(str(pid))
            keeper = mr.Keeper(pid)
            keeper.start()
            break
    w.kill()
    if pid is None:
        sys.exit("Search didn't start")
    for _ in range(150):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    return pid, keeper


def wait_loaded(name_or_id, within=120):
    end = time.time() + within
    while time.time() < end:
        for x in sv.cmd({"do": "extensions"})["extensions"]:
            if (x["id"] == name_or_id or x.get("store") == name_or_id or name_or_id in json.dumps(x)) and x["loaded"]:
                return x
        time.sleep(1)
    return None


def sample(pid, t0):
    procs, total = mr.group(pid)
    app = next((b for p, b, _ in procs if p == pid), 0)
    fds = len(mr.run(["lsof", "-p", str(pid)]).splitlines())
    return {"t": round(time.time() - t0), "app_MB": mr.mb(app), "total_MB": mr.mb(total), "procs": len(procs), "fds": fds,
            "each": sorted(([name, mr.mb(b)] for p, b, name in procs if p != pid), key=lambda x: -x[1])}


def detail(pid, folder, tag):
    os.makedirs(folder, exist_ok=True)
    Path(f"{folder}/{tag}.footprint.txt").write_text(mr.run(["footprint", "-p", str(pid)]))
    Path(f"{folder}/{tag}.vmmap.txt").write_text(mr.run(["vmmap", "--summary", str(pid)]))
    Path(f"{folder}/{tag}.heap.txt").write_text(mr.run(["heap", "-s", str(pid)]))


def main():
    # Stopped from outside: still put everything away.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))
    ap = argparse.ArgumentParser()
    ap.add_argument("--ext", action="append")
    ap.add_argument("--minutes", type=float, default=90)
    ap.add_argument("--every", type=float, default=120)
    ap.add_argument("--tabs", type=int, default=4)
    ap.add_argument("--sites", action="store_true")
    ap.add_argument("--out")
    ap.add_argument("--detail")
    ap.add_argument("--mallocstack", action="store_true")
    ap.add_argument("--world", default="mem-soak")
    ap.add_argument("--host", choices=sorted(HOSTS), help="a stand-in for Bitwarden's desktop app's native host")
    ap.add_argument("--url", action="append", default=[], help="another page to keep open (\"write\": a local page to write in)")
    ap.add_argument("--favicons", action="store_true", help="the busy pages also redraw their favicon every 2 s")
    ap.add_argument("--quiet", type=float, help="quiet pages instead: a title change every QUIET seconds")
    ap.add_argument("--app", help="another build (a copy kept for before/after)")
    a = ap.parse_args()
    exts = a.ext or [BITWARDEN]
    global QUIET_MS, FAVICONS
    FAVICONS = a.favicons
    if a.quiet:
        QUIET_MS = int(a.quiet * 1000)

    sv.use(a.world)
    sv.srv.RequestHandlerClass = Pages
    work = Path(os.path.realpath(tempfile.mkdtemp(prefix="search-memsoak-")))
    sv.APP = probe_copy(work, a.app)
    out = open(a.out, "a") if a.out else sys.stdout
    def emit(d):
        out.write(json.dumps(d) + "\n")
        out.flush()
    pid = keeper = None
    try:
        sv.setup()
        # Tabs stay awake for the whole run.
        subprocess.run(["defaults", "write", sv.SUITE, "sleep.after", "-float", "1000000"])
        if a.host:
            native_host(a.host, work, exts)
        env = ["MallocStackLogging=lite"] if a.mallocstack else []
        pid, keeper = start(env)
        emit({"start": pid, "exts": exts, "tabs": a.tabs, "sites": a.sites})
        sv.cmd({"do": "ext-answer", "answer": "yes"})
        for e in exts:
            sv.cmd({"do": "ext-add", "id": e, "yes": True})
            x = wait_loaded(e)
            emit({"ext": e, "loaded": bool(x), "name": x and x["name"], "version": x and x.get("version")})
            if not x:
                print(json.dumps(sv.cmd({"do": "extensions"})), file=sys.stderr)
        for n in range(a.tabs):
            sv.cmd({"do": "open", "url": f"{sv.BASE}/{'quiet' if a.quiet else 'churn'}{n}"})
        for url in a.url:
            sv.cmd({"do": "open", "url": f"{sv.BASE}/write" if url == "write" else url})
        if a.sites:
            for url in ("https://accounts.google.com/", "https://www.messenger.com/", "https://github.com/login"):
                sv.cmd({"do": "open", "url": url})
        time.sleep(20)
        if a.detail:
            detail(pid, a.detail, "start")
        t0 = time.time()
        while time.time() - t0 < a.minutes * 60:
            s = sample(pid, t0)
            s["onscreen"], s["front"] = keeper.onscreen, keeper.front
            try:
                xs = sv.cmd({"do": "extensions"})["extensions"]
                s["workerStarts"] = {x["name"][:12]: x.get("workerStarts") for x in xs}
                s["reported"] = {x["name"][:12]: [len(x.get("reported", [])), (x.get("reported") or [""])[-1][:120]] for x in xs}
            except Exception as e:
                s["workerStarts"] = str(e)
            emit(s)
            if keeper.onscreen or keeper.front:
                emit({"abort": "a window of the probe reached the screen"})
                break
            if subprocess.run(["kill", "-0", str(pid)], capture_output=True).returncode:
                emit({"abort": "the app quit"})
                break
            time.sleep(a.every)
        if a.detail:
            detail(pid, a.detail, "end")
        if a.mallocstack and a.detail:
            Path(f"{a.detail}/end.heap-addresses.txt").write_text(mr.run(["heap", "-s", "-guessNonObjects", str(pid)]))
    finally:
        if keeper:
            keeper.stop = True
        sv.finish()
        if pid:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        for kind in ("WebKit", "Caches", "HTTPStorages"):
            shutil.rmtree(Path.home() / "Library" / kind / BUNDLE, ignore_errors=True)
        subprocess.run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                        "-u", sv.APP], capture_output=True)
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
