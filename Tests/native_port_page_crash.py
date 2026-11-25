#!/usr/bin/env python3
"""When an extension's page loses its process, its worker's port to an app
goes too, and the log says why (a 1Password report: the connection to the
app closed a fifth of a second in, "this page kept crashing", and Search's
log said nothing), in a hidden probe.

Build first (`./build.sh debug`), then `python3 Tests/native_port_page_crash.py`.
It runs a copy of build/Search.app under a bundle id of its own, in a world
of its own with split_view.py's harness, started hidden; the copy, its
WebKit folders and the world are removed afterwards.

An extension's pages and its worker share one web process. Here the worker
opens a port to a host of the probe's own; then the process of the
extension's page (a tab) is killed, as a crash would end it. Checked:

- the host is stopped within a second of the crash (as Chrome would: the
  worker that held the port is gone);
- the log, at the default level, says the extension's process ended, that
  the port was closed by the extension because of it, and how long after
  the host started, in hundredths of a second.
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

sv.use("native-port-page-crash")
BUNDLE = "com.officecommun.search.nativeportpagecrash"
HOST = "com.officecommun.search.probe.echo"
work = Path(tempfile.mkdtemp(prefix="search-nativeportpagecrash-"))
log = work / "host.log"

# The host: echoes each message, and notes when it starts and how it ends.
HOST_SCRIPT = f"""#!/usr/bin/python3 -I
import json, os, signal, struct, sys, time
LOG = {str(log)!r}
def note(s):
    with open(LOG, "a") as f: f.write(json.dumps({{"pid": os.getpid(), "t": time.time(), "what": s}}) + "\\n")
note("start")
signal.signal(signal.SIGTERM, lambda *a: (note("term"), sys.exit(0)))
while True:
    head = sys.stdin.buffer.read(4)
    if len(head) < 4:
        note("eof"); break
    body = sys.stdin.buffer.read(struct.unpack("<I", head)[0])
    m = json.loads(body)
    note("got " + json.dumps(m))
    out = json.dumps({{"echo": m}}).encode()
    sys.stdout.buffer.write(struct.pack("<I", len(out)) + out); sys.stdout.buffer.flush()
"""

FILES = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "NativeIdle", "version": "1.0",
        "background": {"service_worker": "bg.js"},
        "permissions": ["storage", "nativeMessaging"],
    }),
    # Asked by a page of its own ("go"), opens one port, says hello, then
    # waits. "ping" has it send one more, to see the port still answers.
    "bg.js": f"""
const started = Date.now();
chrome.storage.local.get("starts").then(v => chrome.storage.local.set({{ starts: (v.starts || 0) + 1, started }}));
let port = null;
chrome.runtime.onMessage.addListener((m, s, reply) => {{
  if (m === "go" && !port) {{
    port = chrome.runtime.connectNative({HOST!r});
    port.onMessage.addListener(m => chrome.storage.local.set({{ ["echo_" + (m.echo && m.echo.n)]: Date.now() - started }}));
    port.onDisconnect.addListener(() => chrome.storage.local.set({{ gone: Date.now() - started }}));
    port.postMessage({{ n: "hello" }});
  }}
  if (m === "ping" && port) port.postMessage({{ n: "ping" }});
  reply(started);
}});
""",
    "page.html": "<!doctype html><p>page</p>",
}


def probe_copy():
    """build/Search.app under a bundle id of its own, signed ad hoc."""
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def stored(tid):
    key = f"__r{int(time.time() * 1000)}"
    sv.ev(tid, f"window.{key}=null;chrome.storage.local.get(null).then(v=>window.{key}=JSON.stringify(v));1")
    for _ in range(20):
        value = sv.ev(tid, f"window.{key}")
        if value:
            return json.loads(value)
        time.sleep(0.25)
    return {}


def opened(ext_id):
    """A page of the extension's own, once its chrome.runtime is there."""
    tid = sv.cmd({"do": "ext-page", "id": ext_id, "path": "page.html"})["id"]
    for _ in range(40):
        try:
            if sv.ev(tid, "typeof chrome !== 'undefined' && !!chrome.runtime && document.readyState === 'complete'"):
                return tid
        except RuntimeError:
            pass
        time.sleep(0.25)
    return tid


def notes():
    if not log.exists():
        return []
    return [json.loads(line) for line in log.read_text().splitlines() if line.strip()]


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
    try:
        sv.setup()
        hosts.mkdir(parents=True, exist_ok=True)
        (hosts / f"{HOST}.json").write_text(json.dumps({
            "name": HOST, "description": "probe", "path": str(program), "type": "stdio",
            "allowed_origins": [],  # filled in once the extension's id is known
        }))
        sv.launch()
        sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
        ext = None
        for _ in range(60):
            ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == "NativeIdle" and x["loaded"]), None)
            if ext:
                break
            time.sleep(0.25)
        t.ok("the extension loads", ext is not None)
        if not ext:
            return t
        # The origin Chrome would pass: now the id is known, let it in, and
        # start the worker again so it connects with the host allowed.
        (hosts / f"{HOST}.json").write_text(json.dumps({
            "name": HOST, "description": "probe", "path": str(program), "type": "stdio",
            "allowed_origins": [f"chrome-extension://{ext['id']}/"],
        }))
        page = opened(ext["id"])
        sv.ev(page, "chrome.runtime.sendMessage('go').catch(() => {});1")
        first = {}
        for _ in range(40):
            first = stored(page)
            if "echo_hello" in first:
                break
            time.sleep(0.5)
        t.ok("the host answers the worker's hello", "echo_hello" in first, (first, notes()))
        if "echo_hello" not in first:
            return t
        tabs = sv.cmd({"do": "tabs"}).get("tabs", [])
        pid = next((x["process"] for x in tabs if str(x.get("url", "")).startswith(f"chrome-extension://{ext['id']}/")), 0)
        t.ok("the extension's page has a process", pid > 0, tabs)
        if not pid:
            return t
        since = time.strftime("%Y-%m-%d %H:%M:%S")
        crashed = time.time()
        subprocess.run(["kill", "-9", str(pid)])
        time.sleep(3)
        ended = [n for n in notes() if n["what"] in ("eof", "term")]
        t.ok("the worker's host is stopped within a second", bool(ended) and ended[0]["t"] - crashed < 1, notes())
        app = ",".join(sorted(sv.started))
        said = subprocess.run(["/usr/bin/log", "show", "--start", since, "--style", "compact", "--predicate",
                               f'subsystem == "com.officecommun.search" AND category == "ExtensionNative" AND processID IN {{{app}}}'],
                              capture_output=True, text=True).stdout
        lines = [l for l in said.splitlines() if "ExtensionNative" in l]
        t.ok("the log says the extension's process ended", any("An extension's process ended (crash" in l for l in lines), lines)
        t.ok("and that the port closed because of it, with when",
             any(f"Port to {HOST} closed by the extension" in l and "its process had just ended" in l and " s after its host started" in l for l in lines), lines)
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
