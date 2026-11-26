#!/usr/bin/env python3
"""Ports to an app on the Mac under stress, in a hidden probe (idea 797:
1Password's "This page kept crashing.", 37 WebContent crash reports in
WebKit's dispatchPortMessageEvent a fraction of a second after the
extension's process started, as its port to 1Password's helper opened).

Build first (`./build.sh debug`), then `python3 Tests/native_port_crash_burst.py
[scenario]`. It runs a copy of build/Search.app under a bundle id of its
own, in a world of its own with split_view.py's harness, started hidden;
the copy, its WebKit folders and the world are removed afterwards. A test
extension talks to a host of the probe's own that can answer in bursts,
stream, or speak first. No real app, no account.

Each scenario counts WebContent crash reports of this probe's own (their
coalition is the probe's bundle id): an extension page or worker with a
port to the app while the page reloads, closes, navigates or its process is
killed; ports opened and dropped in a loop; ports to the browser itself.
And: an app that speaks before the worker has said a word is still heard
by the worker, all of it, once PortRelay lets it go.
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

sv.use("native-port-crash-burst")
BUNDLE = "com.officecommun.search.nativeportburst"
HOST = "com.officecommun.search.probe.flood"
work = Path(tempfile.mkdtemp(prefix="search-nativeportburst-"))
log = work / "host.log"
REPORTS = Path.home() / "Library/Logs/DiagnosticReports"
SCENARIO = sys.argv[1] if len(sys.argv) > 1 else "all"

# The host: {"burst": n} answers n messages at once; {"stream": ms} answers
# one every ms milliseconds until its input closes.
HOST_SCRIPT = f"""#!/usr/bin/python3 -I
import json, os, signal, struct, sys, threading, time
LOG = {str(log)!r}
lock = threading.Lock()
def note(s):
    with open(LOG, "a") as f: f.write(json.dumps({{"pid": os.getpid(), "t": time.time(), "what": s}}) + "\\n")
def say(m):
    out = json.dumps(m).encode()
    with lock:
        sys.stdout.buffer.write(struct.pack("<I", len(out)) + out); sys.stdout.buffer.flush()
note("start")
MODE = open({str(work / "mode")!r}).read().strip() if os.path.exists({str(work / "mode")!r}) else ""
if MODE == "eager":
    for i in range(300): say({{"e": i, "pad": "x" * 300}})
signal.signal(signal.SIGTERM, lambda *a: (note("term"), os._exit(0)))
def stream(every):
    n = 0
    while True:
        n += 1
        try: say({{"s": n, "pad": "x" * 200}})
        except Exception: os._exit(0)
        time.sleep(every / 1000)
while True:
    head = sys.stdin.buffer.read(4)
    if len(head) < 4:
        note("eof"); os._exit(0)
    m = json.loads(sys.stdin.buffer.read(struct.unpack("<I", head)[0]))
    if "burst" in m:
        for i in range(m["burst"]): say({{"b": i, "pad": "x" * 200}})
    elif "stream" in m:
        threading.Thread(target=stream, args=(m["stream"],), daemon=True).start()
    else:
        say({{"echo": m}})
"""

FILES = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "NativeBurst", "version": "1.0",
        "background": {"service_worker": "bg.js"},
        "permissions": ["storage", "nativeMessaging", "idle"],
    }),
    "bg.js": f"""
let port = null;
// As 1Password's worker does: a port to its app as soon as it starts.
chrome.storage.local.get("eager").then((v) => {{
  if (!v.eager) return;
  const p = chrome.runtime.connectNative({HOST!r});
  let got = 0;
  p.onMessage.addListener(() => {{ got++; chrome.storage.local.set({{ eagerGot: got }}); }});
  p.postMessage({{ hello: 1 }});
}});
chrome.runtime.onMessage.addListener((m, s, reply) => {{
  if (m && m.worker === "browser-ports") {{
    // Ports to the browser itself, that Search answers on as they open
    // ("ready"), opened many at once and some let go at once.
    for (let i = 0; i < (m.n || 40); i++) {{
      for (const name of (m.names || ["search.socket"])) {{
        try {{
          const p = chrome.runtime.connectNative(name);
          p.onMessage.addListener(() => {{}});
          if (i % 2) p.disconnect();
        }} catch (e) {{}}
      }}
    }}
  }}
  if (m && m.worker === "churn") {{
    // Open, hear the first word, drop, open again: as an extension does
    // that gives up on an answer it didn't like, with the app talking fast.
    let left = m.n || 100;
    const one = () => {{
      if (left-- <= 0) return;
      let p = chrome.runtime.connectNative({HOST!r});
      let done = false;
      const next = () => {{ if (done) return; done = true; try {{ p.disconnect(); }} catch (e) {{}} p = null; setTimeout(one, m.gap || 0); }};
      p.onMessage.addListener(next);
      p.onDisconnect.addListener(next);
      p.postMessage({{ burst: 200 }});
      setTimeout(next, 300);
    }};
    for (let i = 0; i < (m.lanes || 4); i++) one();
  }}
  if (m && m.worker === "stream" && !port) {{
    port = chrome.runtime.connectNative({HOST!r});
    let got = 0;
    port.onMessage.addListener(() => {{ got++; if (got % 10 === 1) chrome.storage.local.set({{ workerGot: got }}); }});
    port.onDisconnect.addListener(() => {{ port = null; chrome.storage.local.set({{ workerGone: true }}); }});
    port.postMessage({{ stream: m.every || 5 }});
  }}
  reply(true);
}});
// Pages talk to the worker over a runtime port too, as 1Password's do.
chrome.runtime.onConnect.addListener((p) => {{
  p.onMessage.addListener((m) => {{ for (let i = 0; i < (m.burst || 1); i++) p.postMessage({{ i, pad: "y".repeat(200) }}); }});
}});
""",
    "page.html": "<!doctype html><p>page</p><script src='page.js'></script>",
    # The page connects to the app at once, as 1Password's unlock page does.
    "page.js": f"""
const mode = location.hash.slice(1) || sessionStorage.mode || "";
window.got = 0;
if (mode.startsWith("native")) {{
  const p = chrome.runtime.connectNative({HOST!r});
  p.onMessage.addListener(() => {{ window.got++; }});
  p.onDisconnect.addListener(() => {{ window.gone = true; }});
  p.postMessage(mode === "native-stream" ? {{ stream: 2 }} : {{ burst: 400 }});
}}
if (mode === "runtime") {{
  const p = chrome.runtime.connect({{ name: "page" }});
  p.onMessage.addListener(() => {{ window.got++; }});
  p.postMessage({{ burst: 400 }});
}}
""",
}


def probe_copy():
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def crashes(since):
    """This probe's WebContent crash reports since `since`, by top frame."""
    found = []
    for f in REPORTS.glob("com.apple.WebKit.WebContent-*.ips"):
        if f.stat().st_mtime < since:
            continue
        try:
            first, _, rest = f.read_text(errors="replace").partition("\n")
            body = json.loads(rest)
        except Exception:
            continue
        if body.get("coalitionName") != BUNDLE:
            continue
        thread = body["threads"][body.get("faultingThread", 0)]
        names = [fr.get("symbol", "?") for fr in thread.get("frames", [])[:5]]
        found.append(next((n for n in names if "dispatchPortMessageEvent" in n), names[0] if names else "?")[:80])
    return found


def tab_pids(ext_id):
    tabs = sv.cmd({"do": "tabs"}).get("tabs", [])
    return [(x["id"], x.get("process")) for x in tabs if str(x.get("url", "")).startswith(f"chrome-extension://{ext_id}/")]


def wait_ready(tid):
    for _ in range(40):
        try:
            if sv.ev(tid, "typeof chrome !== 'undefined' && !!chrome.runtime && document.readyState === 'complete'"):
                return True
        except RuntimeError:
            pass
        time.sleep(0.25)
    return False


def open_page(ext_id, mode):
    """The extension's page, talking in `mode` (kept in sessionStorage: a
    # in the bench's path would be escaped)."""
    tid = sv.cmd({"do": "ext-page", "id": ext_id, "path": "page.html"})["id"]
    wait_ready(tid)
    sv.ev(tid, f"sessionStorage.mode = {json.dumps(mode)}; location.reload(); 1")
    time.sleep(0.3)
    wait_ready(tid)
    return tid


def main():
    t = sv.T()
    folder = work / "ext"
    folder.mkdir()
    for name, body in FILES.items():
        (folder / name).write_text(body)
    program = work / "host.py"
    program.write_text(HOST_SCRIPT)
    program.chmod(0o755)
    sv.APP = probe_copy()
    hosts = Path(sv.SUPPORT) / "NativeMessagingHosts"
    began = time.time()
    try:
        sv.setup()
        hosts.mkdir(parents=True, exist_ok=True)
        sv.launch()
        sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
        ext = None
        for _ in range(60):
            ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == "NativeBurst" and x["loaded"]), None)
            if ext:
                break
            time.sleep(0.25)
        t.ok("the extension loads", ext is not None)
        if not ext:
            return t
        (hosts / f"{HOST}.json").write_text(json.dumps({
            "name": HOST, "description": "probe", "path": str(program), "type": "stdio",
            "allowed_origins": [f"chrome-extension://{ext['id']}/"],
        }))
        base = f"chrome-extension://{ext['id']}/page.html"

        def run(name, steps):
            if SCENARIO not in ("all", name):
                return
            mark = time.time()
            steps()
            time.sleep(4)
            got = crashes(mark)
            print(f"  [{name}] crashes: {len(got)} {sorted(set(got))[:3]}")
            t.ok(f"{name}: no WebContent crash", not got, got)

        def page_reloads(mode, times=8, gap=0.05):
            def steps():
                tid = open_page(ext["id"], mode)
                time.sleep(0.5)
                print("   got before reloads", sv.ev(tid, "window.got"))
                for _ in range(times):
                    try:
                        sv.ev(tid, "location.reload();1")
                    except RuntimeError:
                        pass
                    time.sleep(gap)
                time.sleep(1)
                print("   pids", tab_pids(ext["id"]))
                sv.cmd({"do": "close", "id": tid})
            return steps

        def page_closes(mode, times=6):
            def steps():
                for _ in range(times):
                    tid = open_page(ext["id"], mode)
                    sv.cmd({"do": "close", "id": tid})
                    time.sleep(0.1)
            return steps

        def page_navigates(mode, times=6):
            def steps():
                tid = open_page(ext["id"], mode)
                for i in range(times):
                    try:
                        sv.ev(tid, f"location.href={json.dumps(base + '?n=' + str(i))};1")
                    except RuntimeError:
                        pass
                    time.sleep(0.1)
                time.sleep(1)
                sv.cmd({"do": "close", "id": tid})
            return steps

        def worker_stream_then_kill():
            tid = open_page(ext["id"], "none")
            sv.ev(tid, "chrome.runtime.sendMessage({worker:'stream', every: 3}).catch(()=>{});1")
            time.sleep(1.5)
            pids = tab_pids(ext["id"])
            print("   pids before", pids)
            for _, pid in pids:
                if pid:
                    subprocess.run(["kill", "-9", str(pid)])
                    break
            time.sleep(1)
            # The tab comes back (or is asked to): a fresh process.
            for _ in range(5):
                sv.cmd({"do": "reload"})
                time.sleep(0.6)
            print("   pids after", tab_pids(ext["id"]))
            sv.cmd({"do": "close", "id": tid})

        def page_stream_then_kill():
            tid = open_page(ext["id"], "native-stream")
            time.sleep(1)
            pids = tab_pids(ext["id"])
            print("   pids before", pids)
            for _, pid in pids:
                if pid:
                    subprocess.run(["kill", "-9", str(pid)])
                    break
            time.sleep(0.3)
            for _ in range(5):
                sv.cmd({"do": "reload"})
                time.sleep(0.6)
            print("   pids after", tab_pids(ext["id"]))
            sv.cmd({"do": "close", "id": tid})

        eager_counts = []

        def eager_restarts():
            (work / "mode").write_text("eager")
            tid = open_page(ext["id"], "none")
            sv.ev(tid, "chrome.storage.local.set({eager: true, eagerGot: 0}); 1")
            time.sleep(0.5)
            sv.cmd({"do": "ext-reload", "id": ext["id"]})
            time.sleep(2)
            for i in range(6):
                pids = tab_pids(ext["id"])
                for _, pid in pids:
                    if pid:
                        subprocess.run(["kill", "-9", str(pid)])
                        break
                time.sleep(0.4)
                sv.cmd({"do": "reload"})
                time.sleep(0.8)
                try:
                    sv.ev(tid, "chrome.runtime.sendMessage({wake: 1}).catch(() => {}); 1")
                except RuntimeError as e:
                    print("   wake failed", e)
                time.sleep(1.5)
                try:
                    sv.ev(tid, "window.__g = null; chrome.storage.local.get('eagerGot').then(v => window.__g = v.eagerGot || 0); 1")
                    time.sleep(0.3)
                    got = sv.ev(tid, "window.__g")
                    print("   eagerGot", got)
                    eager_counts.append(got or 0)
                except RuntimeError as e:
                    print("   eval failed", e)
            print("   pids after", tab_pids(ext["id"]))
            lines = log.read_text().splitlines() if log.exists() else []
            print("   host notes", len(lines), [l[-60:] for l in lines[-8:]])
            sv.cmd({"do": "close", "id": tid})
            (work / "mode").write_text("")

        run("eager-host-restarts", eager_restarts)
        if SCENARIO in ("all", "eager-host-restarts"):
            # What an app says before the worker has said a word still
            # reaches it, all of it, held until it speaks (idea 797).
            t.ok("an app that speaks first is heard by the worker", bool(eager_counts) and max(eager_counts) >= 300, eager_counts)

        def churn():
            tid = open_page(ext["id"], "none")
            sv.ev(tid, "chrome.runtime.sendMessage({worker: 'churn', n: 150, lanes: 4}).catch(() => {}); 1")
            time.sleep(25)
            lines = log.read_text().splitlines() if log.exists() else []
            print("   host starts", sum('"start"' in l for l in lines), "pids", tab_pids(ext["id"]))
            sv.cmd({"do": "close", "id": tid})

        run("worker-churn", churn)

        def count():
            for mode in ("native-burst", "native-stream"):
                tid = open_page(ext["id"], mode)
                for wait in (0.5, 2, 4):
                    time.sleep(wait)
                    print(f"   {mode} got after +{wait}s", sv.ev(tid, "window.got"), "gone", sv.ev(tid, "!!window.gone"))
                lines = log.read_text().splitlines() if log.exists() else []
                print("   host notes", [l[-70:] for l in lines[-4:]])
                sv.cmd({"do": "close", "id": tid})
            app = ",".join(sorted(sv.started))
            said = subprocess.run(["/usr/bin/log", "show", "--last", "2m", "--style", "compact", "--predicate",
                                   f'subsystem == "com.officecommun.search" AND processID IN {{{app}}}'], capture_output=True, text=True).stdout
            print("\n".join(l[-200:] for l in said.splitlines()[-25:]))

        def browser_ports():
            tid = open_page(ext["id"], "none")
            for round in range(6):
                try:
                    sv.ev(tid, "chrome.runtime.sendMessage({worker: 'browser-ports', n: 60, names: ['search.socket', 'search.fetch', 'search.idle']}).catch(() => {}); 1")
                except RuntimeError as e:
                    print("   send failed", e)
                time.sleep(1.5)
            print("   pids", tab_pids(ext["id"]))
            sv.cmd({"do": "close", "id": tid})

        run("browser-ports", browser_ports)
        run("count", count)

        def worker_count():
            tid = open_page(ext["id"], "none")
            sv.ev(tid, "chrome.runtime.sendMessage({worker:'stream', every: 3}).catch(()=>{});1")
            for wait in (1, 2, 4):
                time.sleep(wait)
                sv.ev(tid, "chrome.storage.local.get(null).then(v => window.__v = JSON.stringify(v)); 1")
                time.sleep(0.3)
                print(f"   worker after +{wait}s", sv.ev(tid, "window.__v"))
            sv.cmd({"do": "close", "id": tid})

        run("worker-count", worker_count)
        run("native-burst-reload", page_reloads("native-burst"))
        run("native-stream-reload", page_reloads("native-stream"))
        run("runtime-burst-reload", page_reloads("runtime"))
        run("native-stream-close", page_closes("native-stream"))
        run("native-stream-navigate", page_navigates("native-stream"))
        run("page-stream-kill", page_stream_then_kill)
        run("worker-stream-kill", worker_stream_then_kill)
        print("  all crashes this run:", len(crashes(began)))
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
