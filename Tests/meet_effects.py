#!/usr/bin/env python3
"""Google Meet's camera effects (background blur) under the Meet mini
window's Chrome user agent (MeetPiP.swift), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/meet_effects.py`. Needs the
network. Two hidden runs, each on Meet's own public page
(https://meet.google.com/robots.txt — a page of its origin, no sign-in, no call): there the page runs
Meet's own effects pipeline — the script Meet loads for blur and
backgrounds from www.gstatic.com/video_effects, which only meet.google.com
may use — driven as Meet's page drives it (createBundleProcessorWithOptions,
initializeInputStream, requestEffects) with WebKit's pretend camera:

1. the mini window off: no shim, Safari's user agent, what Meet gets in
   Safari — the reference;
2. the mini window on: Chrome's user agent, as the shim gives Meet. Before
   the fix the pipeline took Chrome's worker path and died on
   MediaStreamTrackGenerator; now it must do what it does in 1.

Nothing is signed in to, nothing is shown, no sound (no audio is captured).
"""
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("meet-effects")
t = sv.T()

MEET = "https://meet.google.com/robots.txt"
BUNDLE = "https://www.gstatic.com/video_effects/effects/1022492557/brotli/videopipe_bundle.js"

# Run in the page's own world. Trusted Types are enforced on Meet's pages:
# the script's address goes through a policy of the probe's own.
HARNESS = r"""
(function () {
window.R = {stage: 'start', logs: [], errs: [], outs: 0, outTracks: 0, ua: navigator.userAgent};
function txt(m) { try { return typeof m === 'string' ? m : JSON.stringify(m).slice(0, 300); } catch (e) { return String(m); } }
var noop = function () {};
var logger = {
  log: function (m) { var x = txt(m); if (R.logs.length < 60 && x.indexOf('Skipping') < 0) R.logs.push(x); },
  withError: function (e) { return { log: function (m) { R.errs.push((e && (e.name + ': ' + e.message)) + ' | ' + txt(m)); } }; }
};
var imp = { logImpression: noop, logImpressionAtMostOnce: noop, logGilImpression: noop, logGilImpressionAtMostOnce: noop };
var policy = window.trustedTypes ? trustedTypes.createPolicy('searchprobe' + Date.now(), { createScriptURL: function (s) { return s; } }) : null;
function load(src) {
  return new Promise(function (ok, no) {
    var s = document.createElement('script'); s.src = policy ? policy.createScriptURL(src) : src; s.onload = ok;
    s.onerror = function () { no(new Error('could not load ' + src)); }; document.head.appendChild(s);
  });
}
function flags(configs) {
  // What Meet's page hands the pipeline (its _.kDd and _.SCd), the
  // experiments left at their defaults.
  return { release: '1022492557', allowBreakoutBoxWorker: true, allowPreCropping: true, animateRightToLeft: true,
           enableContinuousAutozoomMetadata: true, enableContinuousAutozoomPointOfInterest: true, studioLookHdrnet: true,
           experimentFlags: '', experimentOptions: { minFaceDetectionScore: 0 }, effectExperimentConfigs: configs };
}
function callbacks() {
  return { progressUpdate: function (p) { R.progress = p; }, handleProgress: noop, brightnessData: noop,
           detectionStateChanged: noop, frameMetadata: noop, handGesture: noop, onVideoProcessingEvent: noop,
           setOutputStream: function (s) { R.outs++; window.output = s; R.outTracks = s ? s.getVideoTracks().length : 0;
             R.outIsCamera = !!(s && window.cam && s.getVideoTracks()[0] === cam.getVideoTracks()[0]);
             out.srcObject = s; out.play().catch(noop); },
           unrecoverableError: function (e) { R.errs.push('unrecoverable: ' + (e && (e.name + ': ' + e.message))); } };
}
// How sharp a picture is: the mean difference between neighbouring pixels.
window.sharpness = function (source) {
  var c = document.createElement('canvas'); c.width = 160; c.height = 90;
  var g = c.getContext('2d'); g.drawImage(source, 0, 0, 160, 90);
  var d = g.getImageData(0, 0, 160, 90).data, sum = 0, n = 0;
  for (var y = 0; y < 90; y++) for (var x = 1; x < 160; x++) {
    var i = (y * 160 + x) * 4, j = i - 4;
    sum += Math.abs(d[i] - d[j]) + Math.abs(d[i + 1] - d[j + 1]) + Math.abs(d[i + 2] - d[j + 2]); n++;
  }
  return Math.round(sum / n * 100) / 100;
};
var out = window.out = document.createElement('video'); out.muted = true; out.playsInline = true;
(async function () {
  try {
    R.stage = 'camera';
    var cam = window.cam = await navigator.mediaDevices.getUserMedia({ video: { width: 640, height: 360 } });
    R.camera = cam.getVideoTracks()[0].label;
    var raw = window.raw = document.createElement('video'); raw.muted = true; raw.playsInline = true; raw.srcObject = cam; await raw.play();
    R.stage = 'bundle';
    await load('""" + BUNDLE + r"""');
    R.stage = 'effects';
    // Which effects this pipeline has: every id offered, those it knows kept.
    var all = []; for (var i = 1; i < 1500; i++) all.push({ effectId: i, promoted: false, launchStage: 3 });
    var ui = createBundleProcessorWithOptions({ flags: flags(all), callbacks: callbacks(), logger: logger, impressionLogger: imp }).getEffectsUIData();
    R.effects = ui.length;
    // The background blur: category 1, the lighter of the two.
    var blur = ui.filter(function (x) { return x.category === 1; }).map(function (x) { return x.effectIdNumber; }).sort(function (a, b) { return a - b; });
    if (!blur.length) throw new Error('no blur effect');
    R.blur = blur[0];
    var configs = ui.map(function (x) { return { effectId: x.effectIdNumber, promoted: false, launchStage: 3 }; });
    R.stage = 'create';
    var p = window.processor = createBundleProcessorWithOptions({ flags: flags(configs), callbacks: callbacks(), logger: logger, impressionLogger: imp });
    R.worker = !!(p.options && p.options.useWorkerProcessor);
    p.initializeInputStream(cam, performance.now());
    R.stage = 'request';
    await p.requestEffects({ effectIds: [R.blur] });
    R.stage = 'requested';
  } catch (e) {
    R.errs.push('go: ' + e.name + ': ' + e.message); R.stage = 'failed at ' + R.stage;
  }
})();
})(); 1
"""


def until(cond, within=6):
    end = time.time() + within
    while time.time() < end:
        try:
            if cond(): return True
        except Exception:
            pass
        time.sleep(0.3)
    return cond()


def state(id): return json.loads(sv.ev(id, "JSON.stringify(window.R || {})") or "{}")


def frames(id):
    """The output's picture now and a second later: time going on, and how
    sharp it is beside the camera's own."""
    js = ("JSON.stringify({w:out.videoWidth,t:out.currentTime,"
          "out:out.videoWidth?sharpness(out):null,cam:sharpness(raw)})")
    a = json.loads(sv.ev(id, js)); time.sleep(1.5); b = json.loads(sv.ev(id, js))
    return a, b


def run(name, shim):
    sv.setup(splitView=False)
    for kind in (0, 1, 2):
        subprocess.run(["defaults", "write", sv.SUITE, f"capture.https://meet.google.com|{kind}", "-bool", "true"])
    subprocess.run(["defaults", "write", sv.SUITE, "meet.pip", "-bool", "true" if shim else "false"])
    sv.launch()
    id = sv.sp("open", url=MEET)["resultID"]
    t.ok(f"{name}: Meet's public page, signed in to nothing", until(lambda: sv.ev(id, "location.host") == "meet.google.com" and sv.ev(id, "document.readyState") == "complete", 30), sv.ev(id, "location.href"))
    ua = sv.ev(id, "navigator.userAgent")
    t.ok(f"{name}: Meet's page is told {'Chrome' if shim else 'Safari'}", (" Chrome/" in ua) == shim, ua)
    sv.ev(id, HARNESS)
    t.ok(f"{name}: WebKit's pretend camera, never a real one", until(lambda: "Mock" in (state(id).get("camera") or ""), 15), state(id).get("camera"))
    t.ok(f"{name}: Meet's effects pipeline loads", until(lambda: state(id).get("stage") not in ("start", "camera", "bundle"), 40), state(id))
    t.ok(f"{name}: it runs in the page, Safari's way (no worker fed by MediaStreamTrackProcessor)", until(lambda: "worker" in state(id), 20) and state(id)["worker"] is False, state(id))
    t.ok(f"{name}: the blur is applied with no error", until(lambda: state(id).get("stage") == "requested", 60) and not state(id)["errs"], state(id))
    t.ok(f"{name}: an output stream came back, not the bare camera", until(lambda: state(id).get("outTracks") == 1, 15) and not state(id).get("outIsCamera"), state(id))
    t.ok(f"{name}: its frames come", until(lambda: frames(id)[1]["w"] > 0, 15), frames(id))
    a, b = frames(id)
    t.ok(f"{name}: and keep coming", b["t"] > a["t"] + 0.5, (a, b))
    t.ok(f"{name}: blurred: softer than the camera's own picture", b["out"] is not None and b["out"] < b["cam"] * 0.8, (a, b))
    s = state(id)
    t.ok(f"{name}: still no error", not s["errs"], s["errs"])
    print("   ", name, json.dumps({k: s.get(k) for k in ("stage", "worker", "blur", "effects", "outs")}), "sharpness out/cam", b.get("out"), b.get("cam"))
    sv.ev(id, "cam.getTracks().forEach(function (t) { t.stop(); }); 1")
    sv.finish()


try:
    run("Safari's user agent (mini window off)", shim=False)
    run("Chrome's user agent (mini window on)", shim=True)
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
