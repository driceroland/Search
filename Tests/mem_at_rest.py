#!/usr/bin/env python3
"""Search at rest: memory and processes just after launch, no site open.

Build first (`./build.sh`), then

    python3 Tests/mem_at_rest.py [--rounds 3] [--settle 30] [--welcomed] [--detail DIR] [--out FILE]
    python3 Tests/mem_at_rest.py --page [--typed] [--rounds 3] [--out FILE]

MEM_APP=/path/to/Search.app measures another build (a copy kept for before/after).
MEM_ENV="NAME=value …" adds to the app's environment.

Memory (the default), the method of the browser comparison on the site: a
fresh world (nothing in its folder, defaults or WebKit stores), the app
started hidden (`open -n -g -j`, SEARCH_MEASURE=1 so App Nap is as for
anyone), then after --settle seconds the physical footprint (Activity
Monitor's Memory column) summed over Search and every process it is
responsible for: com.apple.WebKit.WebContent, .Networking and .GPU. Each
round prints the total, the process count, each process, and how long the
first window took to exist in the window server. --welcomed starts on a
blank new tab instead of the first-launch welcome; --detail keeps the main
process's `footprint`, `vmmap --summary` and `heap -s` there.

--page: the first real page after that rest, the cost of anything put off
until a page needs it. The world is welcomed and has the bench on; after
--settle seconds (default 10 with --page) a local page is opened in a
background tab with no click or key before it (the worst case: a page
asked for by a script), or with --typed typed into the new tab's field a
key at a time and Return pressed. The time from the request (or the
Return) to the page's load event is taken on the page's own clock
(page_ms; start_ms to the navigation's start), with the processes there
before and after.

The app is hidden again every quarter second while it runs and each round
says whether a window of it was ever on a screen or frontmost: nothing here
makes, shows, orders in or brings forward a window. One world at a time,
under the shared probe lock for timings:
`lockf -t 900 /private/tmp/claude-501/search-probe.lock python3 Tests/mem_at_rest.py`.
"""
import json
import os
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("mem-at-rest")
if os.environ.get("MEM_APP"):
    sv.APP = os.environ["MEM_APP"]
EXE = os.path.join(sv.APP, "Contents/MacOS/Search")

MEAS_C = r"""
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/resource.h>
#include <mach/mach_time.h>
#include <CoreGraphics/CoreGraphics.h>
extern int responsibility_get_pid_responsible_for_pid(pid_t);
static pid_t ppid_of(pid_t p) { struct proc_bsdinfo bi;
  if (proc_pidinfo(p, PROC_PIDTBSDINFO, 0, &bi, sizeof bi) != sizeof bi) return -1; return bi.pbi_ppid; }
static int descends(pid_t p, pid_t root) { for (int i = 0; i < 64 && p > 1; i++) { if (p == root) return 1; p = ppid_of(p); } return p == root; }
static double now_ms(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
  return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6; }
int main(int argc, char **argv) {
  if (argc >= 3 && !strcmp(argv[1], "mem")) {
    pid_t root = atoi(argv[2]); pid_t pids[8192]; int n = proc_listallpids(pids, sizeof pids);
    unsigned long long total = 0; int count = 0;
    for (int i = 0; i < n; i++) { pid_t p = pids[i]; if (p <= 0) continue;
      if (p != root && responsibility_get_pid_responsible_for_pid(p) != root && !descends(p, root)) continue;
      struct rusage_info_v4 ri; if (proc_pid_rusage(p, RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) continue;
      total += ri.ri_phys_footprint; count++; char name[PROC_PIDPATHINFO_MAXSIZE] = ""; proc_name(p, name, sizeof name);
      printf("  %d %llu %s\n", p, ri.ri_phys_footprint, name); }
    printf("total %llu count %d\n", total, count); return 0; }
  if (argc >= 4 && !strcmp(argv[1], "watch")) {
    const char *exe = argv[2]; double timeout = atof(argv[3]); double t0 = now_ms(); pid_t found = 0;
    while (!found && now_ms() - t0 < timeout) { pid_t pids[8192]; int n = proc_listallpids(pids, sizeof pids);
      for (int i = 0; i < n; i++) { char path[PROC_PIDPATHINFO_MAXSIZE];
        if (pids[i] > 0 && proc_pidpath(pids[i], path, sizeof path) > 0 && !strcmp(path, exe)) { found = pids[i]; break; } }
      if (!found) usleep(2000); }
    if (!found) { printf("timeout\n"); return 1; }
    printf("pid %d %.0f\n", found, now_ms() - t0); fflush(stdout);
    while (now_ms() - t0 < timeout) {
      CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID); int hit = 0;
      for (CFIndex i = 0; list && i < CFArrayGetCount(list); i++) { CFDictionaryRef w = CFArrayGetValueAtIndex(list, i);
        int owner = 0, layer = -1; CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowOwnerPID), kCFNumberIntType, &owner);
        if (owner != found) continue;
        CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowLayer), kCFNumberIntType, &layer);
        CGRect r; CGRectMakeWithDictionaryRepresentation(CFDictionaryGetValue(w, kCGWindowBounds), &r);
        if (layer == 0 && r.size.width >= 300 && r.size.height >= 200) { hit = 1; break; } }
      if (list) CFRelease(list);
      if (hit) { printf("window %.0f\n", now_ms() - t0); return 0; }
      usleep(5000); }
    printf("nowindow\n"); return 2; }
  return 64; }
"""

HIDE_M = r"""
#import <AppKit/AppKit.h>
int main(int argc, char **argv) { @autoreleasepool {
  pid_t pid = atoi(argv[1]);
  NSRunningApplication *a = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
  [a hide];
  CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
  for (NSDictionary *w in (__bridge NSArray *)list) if ([w[(id)kCGWindowOwnerPID] intValue] == pid)
    printf("onscreen layer %d\n", [w[(id)kCGWindowLayer] intValue]);
  if (list) CFRelease(list);
}}
"""

TOOLS = Path(tempfile.gettempdir()) / "search-mem-at-rest-tools"


def tool(name, source, ext, flags):
    TOOLS.mkdir(exist_ok=True)
    src, exe = TOOLS / f"{name}.{ext}", TOOLS / name
    if not exe.exists() or not src.exists() or src.read_text() != source:
        src.write_text(source)
        subprocess.run(["clang", "-O2", "-o", str(exe), str(src), *flags], check=True)
    return str(exe)


MEAS = tool("meas", MEAS_C, "c", ["-framework", "CoreGraphics", "-framework", "CoreFoundation"])
HIDE = tool("hide", HIDE_M, "m", ["-fobjc-arc", "-framework", "AppKit"])


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout


def front_pid():
    out = run(["lsappinfo", "info", "-only", "pid", run(["lsappinfo", "front"]).strip()])
    try:
        return int(out.strip().split("=")[-1])
    except ValueError:
        return None


class Keeper(threading.Thread):
    """Hides the app every quarter second; counts any window of it on a screen, or it frontmost."""
    def __init__(self, pid):
        super().__init__(daemon=True)
        self.pid, self.stop, self.onscreen, self.front = pid, False, 0, 0

    def run(self):
        while not self.stop:
            if "onscreen layer 0" in run([HIDE, str(self.pid)]):
                self.onscreen += 1
            if front_pid() == self.pid:
                self.front += 1
            time.sleep(0.25)


def group(pid):
    """Search and every process it is responsible for: [(pid, bytes, name)], total bytes."""
    lines = run([MEAS, "mem", str(pid)]).splitlines()
    procs = []
    for line in lines[:-1]:
        p, b, name = line.split(None, 2)
        procs.append((int(p), int(b), name.strip()))
    return procs, sum(b for _, b, _ in procs)


def mb(b):
    return round(b / 1048576, 1)


def fresh(welcomed=False, bench=False):
    for p in sv.pids():
        subprocess.run(["kill", p])
    sv.started.clear()
    time.sleep(1)
    sv.wipe()
    if welcomed:
        subprocess.run(["defaults", "write", sv.SUITE, "welcomed", "-bool", "true"])
    if bench:
        subprocess.run(["defaults", "write", sv.SUITE, "bench", "-bool", "true"])


def start():
    """Started hidden, as the comparison did; the pid and how long its first window took."""
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    w = subprocess.Popen([MEAS, "watch", EXE, "30000"], stdout=subprocess.PIPE, text=True)
    time.sleep(0.05)
    extra = [a for e in os.environ.get("MEM_ENV", "").split() for a in ("--env", e)]
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_MEASURE=1", *extra, sv.APP])
    pid = window = keeper = None
    for line in w.stdout:
        if line.startswith("pid "):
            pid = int(line.split()[1])
            sv.started.add(str(pid))
            keeper = Keeper(pid)
            keeper.start()
        elif line.startswith("window "):
            window = int(line.split()[1])
    w.wait()
    if pid is None:
        sys.exit("Search didn't start")
    return pid, window, keeper


def stop(pid, keeper):
    keeper.stop = True
    keeper.join()
    procs, _ = group(pid)
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    alive = []
    for _ in range(150):
        alive = [p for p, _, _ in procs if subprocess.run(["kill", "-0", str(p)], capture_output=True).returncode == 0]
        if not alive:
            break
        time.sleep(0.1)
    for p in alive:
        try:
            os.kill(p, signal.SIGKILL)
        except ProcessLookupError:
            pass
    sv.started.clear()
    time.sleep(2)


def footprint_text(pid):
    return run(["footprint", "-p", str(pid)])


def memory_round(rnd, settle, welcomed, detail):
    fresh(welcomed=welcomed)
    pid, window, keeper = start()
    time.sleep(settle)
    procs, total = group(pid)
    out = {"round": rnd, "MB": mb(total), "procs": len(procs), "window_ms": window,
           "each": [f"{name} {mb(b)}" for _, b, name in sorted(procs, key=lambda x: -x[1])]}
    if detail:
        os.makedirs(detail, exist_ok=True)
        Path(f"{detail}/r{rnd}.footprint.txt").write_text(footprint_text(pid))
        Path(f"{detail}/r{rnd}.vmmap.txt").write_text(run(["vmmap", "--summary", str(pid)]))
        Path(f"{detail}/r{rnd}.heap.txt").write_text(run(["heap", "-s", str(pid)]))
        Path(f"{detail}/r{rnd}.footprint-all.txt").write_text(
            "\n\n".join(footprint_text(p) for p, _, _ in procs))
    out["onscreen"], out["frontmost"] = keeper.onscreen, keeper.front
    stop(pid, keeper)
    return out


def page_round(rnd, settle, typed):
    fresh(welcomed=True, bench=True)
    pid, window, keeper = start()
    for _ in range(300):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.05)
    time.sleep(settle)
    before, total_before = group(pid)
    t0 = time.monotonic()
    if typed:
        # Typed into the new tab's field a key at a time, then Return: timed
        # from the Return.
        answer = sv.cmd({"do": "field", "text": f"{sv.BASE}/first-page", "type": True, "go": True})
        sent = answer["submittedAt"]
        tab = next(t for t in sv.cmd({"do": "tabs"})["tabs"] if t["active"])
    else:
        sent = time.time() * 1000
        tab = sv.cmd({"do": "open", "url": f"{sv.BASE}/first-page"})
    opened = time.monotonic()
    sv.cmd({"do": "wait", "id": tab["id"], "seconds": 20})
    loaded = time.monotonic()
    nav = json.loads(sv.ev(tab["id"], "JSON.stringify((e => ({origin: performance.timeOrigin, response: e.responseEnd, "
                                      "dom: e.domContentLoadedEventEnd, load: e.loadEventEnd}))(performance.getEntriesByType('navigation')[0]))"))
    time.sleep(1)
    after, total_after = group(pid)
    # From the request to the page's load event, on the page's own clock:
    # the processes a first page has to start, then the navigation itself.
    out = {"round": rnd, "page_ms": round(nav["origin"] + nav["load"] - sent),
           "start_ms": round(nav["origin"] - sent), "response_ms": round(nav["origin"] + nav["response"] - sent),
           "open_ms": round((opened - t0) * 1000), "wait_ms": round((loaded - t0) * 1000),
           "procs_before": [n for _, _, n in before], "procs_after": [n for _, _, n in after],
           "MB_before": mb(total_before), "MB_after": mb(total_after),
           "onscreen": keeper.onscreen, "frontmost": keeper.front}
    stop(pid, keeper)
    return out


def main():
    args = sys.argv[1:]
    val = lambda k, d: args[args.index(k) + 1] if k in args else d
    page = "--page" in args
    rounds = int(val("--rounds", 3))
    settle = float(val("--settle", 10 if page else 30))
    outfile = val("--out", None)
    results = []
    try:
        for rnd in range(rounds):
            res = page_round(rnd, settle, "--typed" in args) if page else memory_round(rnd, settle, "--welcomed" in args, val("--detail", None))
            print(json.dumps(res), flush=True)
            results.append(res)
            if outfile:
                with open(outfile, "a") as f:
                    f.write(json.dumps(res) + "\n")
    finally:
        sv.finish()
    key = "page_ms" if page else "MB"
    print(f"median {key}: {statistics.median(r[key] for r in results)}"
          + ("" if page else f", processes {statistics.median(r['procs'] for r in results)}")
          + f", a window on screen or frontmost: {sum(r['onscreen'] + r['frontmost'] for r in results)}")


if __name__ == "__main__":
    main()
