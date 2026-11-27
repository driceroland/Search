#!/usr/bin/env python3
"""Small native tools the energy and memory probes share, built on first use.

`rsample ROOTPID SECONDS` reads proc_pid_rusage for a process and every process
it is responsible for (Search's WebContent, GPU and Networking processes are),
twice, SECONDS apart, and prints one JSON line of per-process deltas: CPU time
(user + system), idle wakeups, interrupt wakeups, instructions, billed energy,
and the physical footprint now.

`plainweb.app` holds a bare WKWebView for every line of a file of addresses, in
an app with no window and no Dock icon: the floor to compare Search's own
processes with (`open -n -g -j plainweb.app --args FILE [nonap] [store] [ctl]
[script]`: nonap holds App Nap off, store a persistent website data store,
ctl a WKWebExtensionController, script 600 small functions as a user script).

`hide ROOTPID` hides that app and prints a line for every window of it on a
screen: a probe that shows one is no result.
"""
import subprocess
import tempfile
from pathlib import Path

FOLDER = Path(tempfile.gettempdir()) / "search-perf-tools"

RSAMPLE_C = r"""
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/resource.h>
#include <mach/mach_time.h>
extern int responsibility_get_pid_responsible_for_pid(pid_t);
typedef struct { pid_t pid; char name[64]; struct rusage_info_v4 ri; } S;
static double toms(uint64_t abs) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return (double)abs * tb.numer / tb.denom / 1e6; }
static pid_t ppid_of(pid_t p) { struct proc_bsdinfo bi; if (proc_pidinfo(p, PROC_PIDTBSDINFO, 0, &bi, sizeof bi) != sizeof bi) return -1; return bi.pbi_ppid; }
static int descends(pid_t p, pid_t root) { for (int i = 0; i < 64 && p > 1; i++) { if (p == root) return 1; p = ppid_of(p); } return p == root; }
static void take(pid_t root, S *out, int *n) {
  pid_t pids[8192]; int c = proc_listallpids(pids, sizeof pids); *n = 0;
  for (int i = 0; i < c && *n < 512; i++) { pid_t p = pids[i]; if (p <= 0) continue;
    if (p != root && responsibility_get_pid_responsible_for_pid(p) != root && !descends(p, root)) continue;
    S *s = &out[*n]; s->pid = p; if (proc_pid_rusage(p, RUSAGE_INFO_V4, (rusage_info_t *)&s->ri) != 0) continue;
    proc_name(p, s->name, sizeof s->name); (*n)++; } }
int main(int argc, char **argv) {
  pid_t root = atoi(argv[1]); double secs = atof(argv[2]);
  static S a[512], b[512]; int na, nb; take(root, a, &na); double t0 = toms(mach_absolute_time());
  usleep((useconds_t)(secs * 1e6)); take(root, b, &nb); double t1 = toms(mach_absolute_time());
  printf("{\"secs\":%.2f,\"procs\":[", (t1 - t0) / 1000); int first = 1;
  for (int j = 0; j < nb; j++) { S *y = &b[j], *x = NULL; for (int i = 0; i < na; i++) if (a[i].pid == y->pid) x = &a[i];
    if (!x) continue;
    double cpu = toms((y->ri.ri_user_time + y->ri.ri_system_time) - (x->ri.ri_user_time + x->ri.ri_system_time));
    printf("%s{\"pid\":%d,\"name\":\"%s\",\"cpu_ms\":%.1f,\"wk_idle\":%llu,\"wk_intr\":%llu,\"instr\":%llu,\"energy_nj\":%llu,\"mb\":%.1f}", first ? "" : ",", y->pid, y->name, cpu,
      y->ri.ri_pkg_idle_wkups - x->ri.ri_pkg_idle_wkups, y->ri.ri_interrupt_wkups - x->ri.ri_interrupt_wkups,
      y->ri.ri_instructions - x->ri.ri_instructions, y->ri.ri_billed_energy - x->ri.ri_billed_energy, y->ri.ri_phys_footprint / 1048576.0); first = 0; }
  printf("]}\n"); return 0; }
"""

PLAINWEB_M = r"""
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
int main(int argc, char **argv) { @autoreleasepool {
  NSApplication *app = [NSApplication sharedApplication];
  [app setActivationPolicy:NSApplicationActivationPolicyProhibited];
  NSString *list = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[1]] encoding:NSUTF8StringEncoding error:nil];
  NSMutableSet *flags = [NSMutableSet new]; for (int i = 2; i < argc; i++) [flags addObject:[NSString stringWithUTF8String:argv[i]]];
  WKWebViewConfiguration *cfg = [WKWebViewConfiguration new];
  cfg.websiteDataStore = [flags containsObject:@"store"]
    ? [WKWebsiteDataStore dataStoreForIdentifier:[[NSUUID alloc] initWithUUIDString:@"5E4C0000-0000-4000-8000-0000000000AA"]]
    : [WKWebsiteDataStore nonPersistentDataStore];
  cfg.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeAll;
  if ([flags containsObject:@"ctl"] && NSClassFromString(@"WKWebExtensionController")) cfg.webExtensionController = [[WKWebExtensionController alloc] init];
  if ([flags containsObject:@"script"]) {
    NSMutableString *s = [NSMutableString stringWithString:@"(function(){var a=0;"];
    for (int i = 0; i < 600; i++) [s appendFormat:@"function f%d(x){var y=x*%d+1;for(var k=0;k<3;k++){y=(y*31+k)%%1000;}return y;} a+=f%d(%d);", i, i, i, i];
    [s appendString:@"window.__a=a;})();"];
    [cfg.userContentController addUserScript:[[WKUserScript alloc] initWithSource:s injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
  }
  if ([flags containsObject:@"nonap"]) [[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep reason:@"probe"];
  static NSMutableArray *views; views = [NSMutableArray new];
  for (NSString *line in [list componentsSeparatedByString:@"\n"]) {
    if (!line.length) continue;
    WKWebView *w = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 1200, 800) configuration:cfg];
    [views addObject:w]; [w loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:line]]];
  }
  [app run];
}}
"""

PLAINWEB_PLIST = """<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>plainweb</string><key>CFBundleIdentifier</key><string>com.officecommun.plainweb.probe</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/><key>LSBackgroundOnly</key><true/></dict></plist>
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


def _build(name, source, ext, flags):
    FOLDER.mkdir(exist_ok=True)
    src, exe = FOLDER / f"{name}.{ext}", FOLDER / name
    if not exe.exists() or not src.exists() or src.read_text() != source:
        src.write_text(source)
        subprocess.run(["clang", "-fobjc-arc", "-O2", "-o", str(exe), str(src), *flags], check=True)
    return exe


def rsample():
    return str(_build("rsample", RSAMPLE_C, "c", []))


def hide():
    return str(_build("hide", HIDE_M, "m", ["-framework", "AppKit"]))


def plainweb_app():
    """The bundle `open` starts: an app of its own, so its helpers' responsible process is it."""
    exe = _build("plainweb", PLAINWEB_M, "m", ["-framework", "Cocoa", "-framework", "WebKit"])
    app = FOLDER / "plainweb.app"
    plist = app / "Contents" / "Info.plist"
    if not plist.exists() or plist.read_text() != PLAINWEB_PLIST or (app / "Contents/MacOS/plainweb").read_bytes() != exe.read_bytes():
        (app / "Contents" / "MacOS").mkdir(parents=True, exist_ok=True)
        (app / "Contents/MacOS/plainweb").write_bytes(exe.read_bytes())
        (app / "Contents/MacOS/plainweb").chmod(0o755)
        plist.write_text(PLAINWEB_PLIST)
        subprocess.run(["codesign", "--force", "-s", "-", str(app)], capture_output=True)
    return str(app)


def sample(pid, secs):
    import json
    out = subprocess.run([rsample(), str(pid), str(secs)], capture_output=True, text=True).stdout
    return json.loads(out)
