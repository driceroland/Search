#!/usr/bin/env python3
"""What does prepending the shim to an extra content_scripts entry cost a
page load?

#997 says a 229 KB shim is parsed per entry per frame. shim_order.py showed
the multiplier is real and that manifest order is honoured, so the cheap fix
(one entry instead of N) is correct. This asks whether it is worth anything:
the saving is (N - 1) parses per frame, and that is only worth a PR if a
parse costs something measurable.

Measured by loading one page with 20 iframes under the same extension with
0, 1 and 3 content_scripts entries, each entry carrying a one-line script.
The only difference between the runs is how many times Search prepends the
shim, so the difference in load time is the shim's parse, nothing else.

Build first (`./build.sh release app`), then `python3 Tests/shim_cost.py`.

The 0-entry run is the baseline and the control at once: an extension with no
content_scripts gets no injection into a page, so if 0 and 3 come back equal,
either the shim costs nothing or the probe is not measuring the shim.
"""
import json
import shutil
import random
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("shim-cost")
BUNDLE = "com.officecommun.search.shimcost"
work = Path(tempfile.mkdtemp(prefix="search-shimcost-"))

KIDS = 20
SAMPLES = 8      # per block
ROUNDS = 3       # blocks per configuration

# Both behaviours, in one build. Entries that agree on where and when they run
# share one copy of the shim; entries that differ in anything, here a
# exclude_matches that excludes nothing, each keep their own, which is what
# every entry did before. So "pooled" and "apiece" are the fix and its absence
# measured against each other on the same page in the same run, with no
# second build to drift against.
CONFIGS = {
    "none": [],
    "one": [{}],
    "pooled": [{}, {}, {}],
    "apiece": [{"exclude_matches": [f"*://nowhere{n}.test/*"]} for n in range(3)],
}


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        parts = urlparse(self.path)
        if parts.path == "/host":
            kids = "".join(f"<iframe src='/kid?i={i}'></iframe>" for i in range(KIDS))
            body = (f"<!doctype html><title>host</title>{kids}"
                    "<script>addEventListener('load',()=>{"
                    # performance.now() at load, not navigation.duration:
                    # duration is still 0 while the load event is running,
                    # and a 0 read as falsy looks exactly like no reading.
                    "window.__done=performance.now();});</script>").encode()
        else:
            body = b"<!doctype html><title>kid</title><p>kid"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
HERE = f"http://127.0.0.1:{srv.server_port}"


def files(name):
    m = {
        "manifest_version": 3, "name": "Shim Cost", "version": "1.0",
        "background": {"service_worker": "sw.js"},
        "host_permissions": ["<all_urls>"],
    }
    out = {"sw.js": "self.oninstall = () => {};\n"}
    extra = CONFIGS[name]
    if extra:
        m["content_scripts"] = [
            {"matches": ["<all_urls>"], "all_frames": True,
             "run_at": "document_start", "js": [f"s{n}.js"], **e}
            for n, e in enumerate(extra)
        ]
        for n in range(len(extra)):
            out[f"s{n}.js"] = f"void {n};\n"
    out["manifest.json"] = json.dumps(m, indent=2)
    return out


def probe_copy():
    app = work / "Search.app"
    if app.exists():
        return str(app)
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}",
                    str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements",
                    str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def wipe_world():
    for kind in ("WebKit", "Caches", "HTTPStorages"):
        shutil.rmtree(Path.home() / "Library" / kind / BUNDLE, ignore_errors=True)


def loads(name):
    """Load times for a host page with KIDS iframes, with the extension
    carrying `entries` content_scripts entries. A fresh world each time, so
    one run's extension never answers the next run's page."""
    folder = work / f"ext-{name}"
    shutil.rmtree(folder, ignore_errors=True)
    folder.mkdir()
    for leaf, body in files(name).items():
        (folder / leaf).write_text(body)
    sv.APP = probe_copy()
    sv.setup()
    sv.launch()
    try:
        sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
        loaded = False
        for _ in range(60):
            if any(x["name"] == "Shim Cost" and x["loaded"]
                   for x in sv.cmd({"do": "extensions"})["extensions"]):
                loaded = True
                break
            time.sleep(0.25)
        if not loaded:
            return None
        out = []
        for i in range(SAMPLES):
            tid = sv.sp("open", url=f"{HERE}/host?n={name}-{i}")["resultID"]
            ms = None
            end = time.time() + 20
            while time.time() < end:
                ms = sv.ev(tid, "window.__done === undefined ? -1 : window.__done")
                if ms is not None and float(ms) >= 0:
                    break
                ms = None
                time.sleep(0.2)
            if ms:
                out.append(float(ms))
            sv.sp("close", id=tid)
            time.sleep(0.4)
        return out
    finally:
        sv.finish()
        wipe_world()


def gap(a, b, runs=4000):
    """A confidence interval for median(b) - median(a), by resampling. The
    point estimate on its own cannot say whether a few milliseconds are the
    shim or the machine, and this probe exists to tell those apart."""
    lo_hi = []
    for _ in range(runs):
        ra = [random.choice(a) for _ in a]
        rb = [random.choice(b) for _ in b]
        lo_hi.append(statistics.median(rb) - statistics.median(ra))
    lo_hi.sort()
    return (statistics.median(lo_hi), lo_hi[int(runs * 0.025)], lo_hi[int(runs * 0.975)])


def main():
    t = sv.T()
    seen = {n: [] for n in CONFIGS}
    try:
        # Round robin, not all of one then all of the next: a machine that
        # warms up or picks up background work over several minutes would give
        # the configuration that ran last a penalty it did not earn.
        for r in range(ROUNDS):
            for n in CONFIGS:
                got = loads(n)
                if not got:
                    t.ok(f"{n}, round {r}: the page reports", False, got)
                    return t
                seen[n] += got
        for n in CONFIGS:
            v = sorted(seen[n])
            q1, q3 = v[len(v) // 4], v[(3 * len(v)) // 4]
            print(f"  {n:8} median {statistics.median(v):6.1f} ms   "
                  f"IQR {q1:.0f} to {q3:.0f}   n={len(v)}")

        first = gap(seen["none"], seen["one"])
        apiece = gap(seen["none"], seen["apiece"])
        pooled = gap(seen["none"], seen["pooled"])
        saved = gap(seen["pooled"], seen["apiece"])
        print(f"\n  one entry, one copy, costs      {first[0]:+5.1f} ms  "
              f"(95% {first[1]:+.1f} to {first[2]:+.1f})")
        print(f"  three entries, a copy apiece    {apiece[0]:+5.1f} ms  "
              f"(95% {apiece[1]:+.1f} to {apiece[2]:+.1f})")
        print(f"  three entries sharing one copy  {pooled[0]:+5.1f} ms  "
              f"(95% {pooled[1]:+.1f} to {pooled[2]:+.1f})")
        print(f"  so sharing saves                {saved[0]:+5.1f} ms  "
              f"(95% {saved[1]:+.1f} to {saved[2]:+.1f})")

        # The control: an extension with no content_scripts gets no injection,
        # so if three entries are not slower than none, nothing above is the
        # shim and no figure here means anything.
        t.ok("having the shim at all costs measurable time, so the probe watches it",
             apiece[1] > 0, apiece)
        # And the question the fix hangs on.
        t.ok("sharing one copy between entries saves more than nothing",
             saved[1] > 0, saved)
    finally:
        srv.shutdown()
        shutil.rmtree(work, ignore_errors=True)
    return t


if __name__ == "__main__":
    t = main()
    t.done()
    sys.exit(1 if t.failed else 0)
