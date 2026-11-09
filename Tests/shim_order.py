#!/usr/bin/env python3
"""Does a content_scripts entry placed first run before the later entries,
in every frame?

That is the one question that decides the fix for #997. Search prepends
search-shim.js to *every* content_scripts entry (ExtensionShims.swift:130),
so a 229 KB shim is parsed once per entry per frame. Injecting it once, as a
single entry at index 0, is a far smaller change than splitting it, but it is
only correct if WebKit runs manifest entries in order: the shim has to be in
place before a password manager's own script takes its reference to
navigator.credentials (ExtensionShims.swift:125-129).

Chrome documents manifest order within the same run_at. Whether WebKit
honours it is measured here, not assumed.

Build first (`./build.sh release app`), then `python3 Tests/shim_order.py`.

Reported by each injected script, from inside the world it runs in:
  s     which entry (0, 1, 2)
  seq   its position in the shared per-frame counter
  frame the frame it ran in

Controls, because a dead probe reads like a finding:
  - a page with no iframes must report exactly one execution per entry; zero
    reports means the extension never injected and nothing below means
    anything;
  - the per-frame counter must come back 1, 2, 3 distinct. All ones means the
    entries do not share a world, the counter is not a clock, and the
    ordering signal is void rather than negative.
"""
import json
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("shim-order")
BUNDLE = "com.officecommun.search.shimorder"
work = Path(tempfile.mkdtemp(prefix="search-shimorder-"))

ENTRIES = 3
WORLDS = ["ISOLATED", "MAIN"]
KIDS = 20
BLANKS = 2

reports = []
lock = threading.Lock()


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        parts = urlparse(self.path)
        if parts.path == "/log":
            try:
                with lock:
                    reports.append(json.loads(parse_qs(parts.query)["r"][0]))
            except Exception:
                pass
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if parts.path == "/host":
            kids = "".join(
                f"<iframe name='kid-{i}' src='/kid?i={i}'></iframe>" for i in range(KIDS)
            ) + "".join(f"<iframe name='blank-{i}'></iframe>" for i in range(BLANKS))
            body = f"<!doctype html><title>host</title>{kids}".encode()
        elif parts.path == "/kid":
            body = b"<!doctype html><title>kid</title><p>kid"
        else:
            body = b"<!doctype html><title>one</title><p>one frame, no iframes"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
HERE = f"http://127.0.0.1:{srv.server_port}"


def script(n, world):
    """One entry's script: record where it landed in the shared counter, then
    report. The counter is read before the fetch, so an out-of-order arrival
    at the log cannot be mistaken for an out-of-order execution."""
    return f"""
(() => {{
  const g = globalThis;
  g.__seen{world} = g.__seen{world} || [];
  g.__seen{world}.push({n});
  const seq = g.__seen{world}.length;
  let frame = "?";
  try {{ frame = window.name || (window === window.top ? "top" : "unnamed"); }} catch (e) {{}}
  // What the fix has to guarantee, asked from inside the extension's own
  // script: the shim has already run in this world, and in the page's world
  // the passkey patch is already on the prototype. A missing
  // CredentialsContainer is reported apart from a missing patch, so "not
  // applicable here" never reads as "the patch did not run".
  let shim = false, patch = false, able = false;
  try {{ shim = !!g.__searchShim; }} catch (e) {{}}
  try {{
    able = !!(window.CredentialsContainer && window.PublicKeyCredential);
    patch = able && !!CredentialsContainer.prototype[Symbol.for("search.passkeys")];
  }} catch (e) {{}}
  const r = {{
    s: {n}, seq, world: "{world}", order: g.__seen{world}.join(","), frame,
    shim, patch, able,
    url: (location.href || "").slice(0, 60), top: window === window.top,
  }};
  try {{ fetch("{HERE}/log?r=" + encodeURIComponent(JSON.stringify(r))); }} catch (e) {{}}
  try {{ chrome.runtime.sendMessage(r); }} catch (e) {{}}
}})();
"""


FILES = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "Shim Order", "version": "1.0",
        "background": {"service_worker": "sw.js"},
        "host_permissions": ["<all_urls>"],
        "content_scripts": [
            {"matches": ["<all_urls>"], "all_frames": True, "world": w,
             "run_at": "document_start", "js": [f"s{w}{n}.js"]}
            for w in WORLDS for n in range(ENTRIES)
        ],
    }, indent=2),
    "sw.js": 'chrome.runtime.onMessage.addListener((m) => { console.log("ORDER " + JSON.stringify(m)); });\n',
}
for w in WORLDS:
    for n in range(ENTRIES):
        FILES[f"s{w}{n}.js"] = script(n, w)


def probe_copy():
    """build/Search.app under a bundle id of its own, signed ad hoc."""
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}",
                    str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements",
                    str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def settle(want, within=12):
    """Wait for the reports to stop arriving, not for a count: a count that is
    waited for is a count that cannot come back short."""
    end = time.time() + within
    last, still = -1, 0
    while time.time() < end:
        with lock:
            now = len(reports)
        if now == last:
            still += 1
            if still >= 6 and now >= want:
                break
        else:
            still = 0
        last = now
        time.sleep(0.4)
    with lock:
        return list(reports)


def main():
    t = sv.T()
    folder = work / "ext"
    folder.mkdir()
    for name, body in FILES.items():
        (folder / name).write_text(body)
    sv.APP = probe_copy()
    try:
        sv.setup()
        sv.launch()
        sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
        ext = None
        for _ in range(60):
            ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"]
                        if x["name"] == "Shim Order" and x["loaded"]), None)
            if ext:
                break
            time.sleep(0.25)
        t.ok("the extension loads", ext is not None)
        if not ext:
            return t

        # Control: one frame, no iframes. Nothing below this line means
        # anything if this comes back empty.
        with lock:
            reports.clear()
        sv.sp("open", url=f"{HERE}/one")
        want = ENTRIES * len(WORLDS)
        got = settle(want)
        t.ok(f"control: a page with no iframes reports once per entry ({want})",
             len(got) == want, [(r["world"], r["s"]) for r in got])
        if not got:
            print("\n  nothing reported at all: the probe is dead, not the ordering.")
            return t

        # Control, per world: do that world's entries share one global? If
        # they do not, seq is not a clock there and the ordering signal for
        # that world is void rather than negative.
        clock = {}
        for w in WORLDS:
            seqs = sorted(r["seq"] for r in got if r["world"] == w)
            clock[w] = seqs == list(range(1, ENTRIES + 1))
            t.ok(f"control: the {w} entries share one world, so the counter is a clock there",
                 clock[w], seqs)

        for w in WORLDS:
            if not clock[w]:
                continue
            order = [r["s"] for r in sorted((r for r in got if r["world"] == w),
                                            key=lambda r: r["seq"])]
            t.ok(f"{w}: manifest order is honoured in the main frame, entry 0 ran first",
                 order == list(range(ENTRIES)), order)

        # The multiplier, and ordering in every frame of a page with iframes.
        with lock:
            reports.clear()
        sv.sp("open", url=f"{HERE}/host")
        pages = 1 + KIDS
        got = settle(want * pages)

        groups = {}
        for r in got:
            groups.setdefault((r["frame"], r["world"]), []).append(r)
        framed = {f for f, _ in groups}
        print(f"\n  {len(got)} executions over {len(framed)} frames "
              f"({ENTRIES} entries x {len(WORLDS)} worlds x {pages} framed pages "
              f"= {want * pages}, plus {BLANKS} about:blank)")

        t.ok(f"the multiplier holds: entries x worlds x frames, at least {want * pages}",
             len(got) >= want * pages, len(got))

        for w in WORLDS:
            if not clock[w]:
                continue
            wrong = {f: [r["s"] for r in sorted(rs, key=lambda r: r["seq"])]
                     for (f, ww), rs in groups.items() if ww == w
                     if [r["s"] for r in sorted(rs, key=lambda r: r["seq"])] != list(range(ENTRIES))}
            t.ok(f"{w}: entry 0 ran first in every frame, iframes included",
                 not wrong, dict(list(wrong.items())[:5]))

        # The guarantee itself, not the mechanism: every one of the
        # extension's own scripts found the shim already run in its world,
        # and every one in the page's world found the passkey patch already
        # on the prototype. This is what a shared copy must not lose.
        late = [(r["frame"], r["world"], r["s"]) for r in got
                if r["world"] == "ISOLATED" and not r["shim"]]
        t.ok("every isolated script found the shim already run in its world",
             not late, late[:5])

        able = [r for r in got if r["world"] == "MAIN" and r["able"]]
        unpatched = [(r["frame"], r["s"]) for r in able if not r["patch"]]
        t.ok(f"every page-world script found the passkey patch already in place "
             f"({len(able)} of {sum(1 for r in got if r['world'] == 'MAIN')} could tell)",
             able and not unpatched, unpatched[:5])

        blanks = {f for f in framed if f.startswith("blank-")}
        print(f"  about:blank frames that ran anything: {len(blanks)} of {BLANKS}")
    finally:
        sv.finish()
        srv.shutdown()
        for kind in ("WebKit", "Caches", "HTTPStorages"):
            shutil.rmtree(Path.home() / "Library" / kind / BUNDLE, ignore_errors=True)
        shutil.rmtree(work, ignore_errors=True)
    return t


if __name__ == "__main__":
    t = main()
    t.done()
    sys.exit(1 if t.failed else 0)
