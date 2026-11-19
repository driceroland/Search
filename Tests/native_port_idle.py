#!/usr/bin/env python3
"""A worker's port to an app on the Mac outlives two idle minutes, in a
hidden probe (#1122).

Build first (`./build.sh debug`), then `python3 Tests/native_port_idle.py`.
It runs a copy of build/Search.app under a bundle id of its own, in a world
of its own with split_view.py's harness, started hidden; the copy, its
WebKit folders and the world are removed afterwards.

Apple's iCloud Passwords extension pairs with its helper over a port its
worker opens with runtime.connectNative, and says nothing on it while you
browse. WebKit unloads a worker whose ports have been quiet for two minutes;
the helper goes with the worker, and with it the pairing, so the extension
asked for a code again every couple of minutes. Chrome keeps such a worker.

Here an extension's worker opens a port to a host of the probe's own (read
from the probe world's NativeMessagingHosts folder), says hello once, and
then nothing. After `IDLE` seconds:

- the host it started is the one still running, never told to stop;
- the worker is the same one (it wrote when it started; no second start);
- the port still answers: a message sent now comes back.

Without the shim's answer to the browser's "alive" (ExtensionShims), WebKit
unloads this worker after about 150 seconds and its host is told to stop:
this probe then fails its last three checks.
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

sv.use("native-port-idle")
BUNDLE = "com.officecommun.search.nativeportidle"
HOST = "com.officecommun.search.probe.echo"
IDLE = int(os.environ.get("IDLE", "170"))
work = Path(tempfile.mkdtemp(prefix="search-nativeportidle-"))
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
        started = [n for n in notes() if n["what"] == "start"]
        time.sleep(IDLE)
        ended = [n for n in notes() if n["what"] in ("eof", "term")]
        t.ok(f"after {IDLE}s idle the host is still running", not ended, notes())
        page = opened(ext["id"])
        sv.ev(page, "chrome.runtime.sendMessage('ping').catch(() => {});1")
        time.sleep(1.5)
        later = stored(page)
        t.ok("the worker is the same one", later.get("starts") == first.get("starts") and later.get("started") == first.get("started"),
             (first, later))
        t.ok("the port still answers", "echo_ping" in later and "gone" not in later, later)
        t.ok("one host, started once", len([n for n in notes() if n["what"] == "start"]) == len(started) == 1, notes())
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
