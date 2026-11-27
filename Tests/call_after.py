#!/usr/bin/env python3
"""What keeps working once a call is over (idea 1258), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/call_after.py [--secs 60] [--rounds 3] [--app PATH]`.

The reporter's Energy Impact stayed at 600-700 after leaving a Google Meet
call, until Search was quit. Here a local call page (WebKit's pretend camera
and microphone, test runs only: ExtensionCapture.mockDevices) sends its
camera and microphone over a loopback RTCPeerConnection, draws the camera
into a WebGL canvas every frame in a worker-free loop, as Meet's effects do,
and keeps a muted <video>. Nothing is ever played out loud: every <video>
is muted and no AudioContext is made.

Each case measures the CPU time of Search and every process it is
responsible for (WebContent, GPU, Networking) over --secs seconds, and
WebKit's own word for what is still capturing:

  idle         a blank page in front, before any call
  call         on the call, its tab in front
  ended        the call ended in the page (tracks stopped, connections
               closed), the tab still open, in front
  closed       then the tab closed
  behind-closed  (second launch) the call going on behind another tab, and
               its tab closed without ending it
  meet-left / meet-closed  (--meet-only runs just these) Meet's way, its
               little window (MeetPiP) open when the call ends: Leave in the
               page, or its tab closed while away; meet-left-then-closed is
               the tab closed afterwards

27 Nov 2026, main 95a16ef4: on the call 30-45 % of a core (GPU, WebContent,
Networking, VTEncoder); after it, every way, all of Search's processes back
to 0.2-1.0 % within seconds, the little window gone. The ~0.6 % left in the
app after some cases also follows a plain animating tab switched away: not
the call's.

The app is hidden every quarter second and the run stops at once if a
window of it reaches a screen.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mem_at_rest as mr  # noqa: E402
import split_view as sv  # noqa: E402

CALL = r"""<!doctype html><title>call</title>
<style>html,body{margin:0;height:100%}</style>
<video id=v autoplay playsinline muted width=320 height=240></video>
<video id=r autoplay playsinline muted width=320 height=240></video>
<canvas id=c width=640 height=480></canvas><script>
window.state = 'starting'; window.frames = 0;
(async () => {
  try {
    const stream = await navigator.mediaDevices.getUserMedia({video: {width: 1280, height: 720}, audio: true});
    window.stream = stream;
    const v = document.getElementById('v'); v.muted = true; v.volume = 0; v.srcObject = stream;
    const a = new RTCPeerConnection(), b = new RTCPeerConnection();
    a.onicecandidate = e => e.candidate && b.addIceCandidate(e.candidate);
    b.onicecandidate = e => e.candidate && a.addIceCandidate(e.candidate);
    b.ontrack = e => { const r = document.getElementById('r'); r.muted = true; r.volume = 0; r.srcObject = e.streams[0]; };
    stream.getTracks().forEach(t => a.addTrack(t, stream));
    await a.setLocalDescription(await a.createOffer()); await b.setRemoteDescription(a.localDescription);
    await b.setLocalDescription(await b.createAnswer()); await a.setRemoteDescription(b.localDescription);
    window.pa = a; window.pb = b;
    // The camera drawn into WebGL every frame, as Meet's effects do.
    const gl = document.getElementById('c').getContext('webgl');
    const tex = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    window.running = true;
    (function f() {
      if (!window.running) return;
      if (v.readyState >= 2) { gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, v); frames++; }
      requestAnimationFrame(f);
    })();
    window.state = 'started';
  } catch (e) { window.state = 'error ' + e.name + ' ' + e.message; }
})();
// Leaving, as Meet does: the camera and microphone stopped, the
// connections closed, the loop ended; the page stays ("You left the call").
window.leave = () => {
  window.running = false;
  stream.getTracks().forEach(t => t.stop()); pa.close(); pb.close();
  for (const id of ['v', 'r']) { const e = document.getElementById(id); if (e) e.srcObject = null; }
  document.body.insertAdjacentHTML('beforeend', '<p>You left the call</p>');
  return 1;
};
</script>"""


# Meet's own way (MeetPiP.swift, as Tests/meet_pip.py): the page gives
# mediaSession an 'enterpictureinpicture' handler that opens
# documentPictureInPicture's window and moves its tile and a camera video
# into it; Search opens it on a tab switch during the call. leave() is
# Meet's Leave: the window closed, the camera and microphone stopped.
MEET = CALL.replace("window.state = 'started';", """window.state = 'started';
    navigator.mediaSession.setActionHandler('enterpictureinpicture', async () => {
      const w = await documentPictureInPicture.requestWindow({width: 300, height: 300});
      window.pipWindow = w;
      w.document.body.appendChild(document.getElementById('r'));
      const cam = w.document.createElement('video'); cam.autoplay = true; cam.muted = true; cam.volume = 0; cam.playsInline = true;
      cam.srcObject = stream; w.document.body.appendChild(cam);
    });""").replace("window.leave = () => {", "window.leave = () => {\n  if (window.pipWindow) pipWindow.close();")


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/")
        page = MEET if name.startswith("meet") else CALL if name.startswith("call") else f"<!doctype html><title>{name}</title><p>{name}"
        body = page.encode()
        self.send_response(200); self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def log_message(self, *a): pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"
sv.BASE = BASE  # sv.page opens pages from here


def cpu_seconds(pids):
    """CPU time (user + system) of each pid, in seconds, from ps."""
    if not pids:
        return {}
    out = subprocess.run(["ps", "-o", "pid=,time=", "-p", ",".join(map(str, pids))], capture_output=True, text=True).stdout
    got = {}
    for line in out.splitlines():
        p, t = line.split()
        parts = t.split(":")
        secs = float(parts[-1]) + 60 * int(parts[-2]) + (3600 * int(parts[-3]) if len(parts) > 2 else 0)
        got[int(p)] = secs
    return got


def measure(pid, secs):
    """Percent of one core over secs, for the app and for all its processes,
    and the busiest process."""
    procs, _ = mr.group(pid)
    names = {p: n for p, _, n in procs}
    a = cpu_seconds(list(names))
    time.sleep(secs)
    procs, _ = mr.group(pid)
    names.update({p: n for p, _, n in procs})
    b = cpu_seconds(list(names))
    each = {p: (b[p] - a.get(p, 0)) / secs * 100 for p in b}
    top = sorted(((round(v, 1), names[p].replace("com.apple.WebKit.", "")) for p, v in each.items()), reverse=True)[:4]
    return {"app_pct": round(each.get(pid, 0), 1), "all_pct": round(sum(each.values()), 1), "procs": len(b), "top": top}


def tab(id):
    return next((x for x in sv.sp("state")["tabs"] if x["id"] == id), None)


def until(cond, within=8):
    end = time.time() + within
    while time.time() < end:
        try:
            if cond():
                return True
        except Exception:
            pass
        time.sleep(0.2)
    return False


def start():
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    exe = os.path.join(sv.APP, "Contents/MacOS/Search")
    w = subprocess.Popen([mr.MEAS, "watch", exe, "30000"], stdout=subprocess.PIPE, text=True)
    time.sleep(0.05)
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_MEASURE=1", sv.APP])
    pid = keeper = None
    for line in w.stdout:
        if line.startswith("pid "):
            pid = int(line.split()[1])
            sv.started.add(str(pid))
            keeper = mr.Keeper(pid)
            keeper.start()
            break
    w.kill()
    for _ in range(150):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(3)
    return pid, keeper


def stop(keeper):
    keeper.stop = True
    sv.quit()
    time.sleep(1)


def fresh():
    sv.setup(splitView=False)
    for kind in (0, 1):
        subprocess.run(["defaults", "write", sv.SUITE, f"capture.{BASE}|{kind}", "-bool", "true"])
    # This server stands in for meet.google.com (MeetPiP.testHostKey).
    subprocess.run(["defaults", "write", sv.SUITE, "meetPiP.testHost", "127.0.0.1"])
    subprocess.run(["defaults", "write", sv.SUITE, "meet.pip", "-bool", "true"])
    subprocess.run(["defaults", "write", sv.SUITE, "sleep.after", "-float", "1000000"])


def safe(keeper):
    if keeper.onscreen or keeper.front:
        sys.exit("a window of the probe reached the screen: stopped")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--secs", type=float, default=60)
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--app")
    ap.add_argument("--out")
    ap.add_argument("--meet-only", action="store_true", help="only the Meet-like cases")
    a = ap.parse_args()
    sv.use("call-after")
    work = None
    if a.app:
        work = Path(os.path.realpath(tempfile.mkdtemp(prefix="search-callafter-")))
        shutil.copytree(a.app, work / "Search.app", symlinks=True)
        sv.APP = str(work / "Search.app")
    out = open(a.out, "a") if a.out else sys.stdout
    def emit(case, d):
        d = {"case": case, **d}
        out.write(json.dumps(d) + "\n"); out.flush()
        if a.out:
            print(json.dumps(d), flush=True)
    keeper = None
    try:
        # One: ended in the page, then the tab closed.
        if not a.meet_only:
            fresh()
            pid, keeper = start()
            sv.page("blank")
            time.sleep(10)
            emit("idle", measure(pid, a.secs)); safe(keeper)
            call = sv.page("call")
            if not until(lambda: sv.ev(call, "window.state") == "started", 15):
                sys.exit(f"the call didn't start: {sv.ev(call, 'window.state')}")
            until(lambda: tab(call)["onCall"])
            emit("call", {**measure(pid, a.secs), "frames": sv.ev(call, "frames")}); safe(keeper)
            sv.ev(call, "leave()")
            until(lambda: not tab(call)["onCall"])
            t = tab(call)
            for r in range(a.rounds):
                emit(f"ended-{r}", {**measure(pid, a.secs), "onCall": t["onCall"], "held": t["heldForCall"]}); safe(keeper)
            sv.sp("closeTab", id=call)
            time.sleep(2)
            for r in range(a.rounds):
                emit(f"closed-{r}", measure(pid, a.secs)); safe(keeper)
            stop(keeper)

            # Two: the call behind another tab, its tab closed while on it.
            fresh()
            pid, keeper = start()
            call = sv.page("call")
            if not until(lambda: sv.ev(call, "window.state") == "started", 15):
                sys.exit(f"the call didn't start: {sv.ev(call, 'window.state')}")
            until(lambda: tab(call)["onCall"])
            other = sv.page("other")
            time.sleep(2)
            t = tab(call)
            emit("behind", {**measure(pid, a.secs), "held": t["heldForCall"], "inWindow": t["inWindow"]}); safe(keeper)
            sv.sp("closeTab", id=call)
            time.sleep(2)
            for r in range(a.rounds):
                emit(f"behind-closed-{r}", measure(pid, a.secs)); safe(keeper)
            stop(keeper)

        # Three and four: Meet's way, its little window open when the call
        # ends: left with Leave (the page closes the window), or the tab
        # closed while away.
        for how in ("meet-left", "meet-closed"):
            fresh()
            pid, keeper = start()
            call = sv.page("meet")
            if not until(lambda: sv.ev(call, "window.state") == "started", 15):
                sys.exit(f"the call didn't start: {sv.ev(call, 'window.state')}")
            until(lambda: len(sv.cmd({"do": "meetpip"})["armed"]) == 1)
            other = sv.page("other")
            opened = until(lambda: len(sv.cmd({"do": "meetpip"})["windows"]) == 1)
            emit(f"{how}-away", {**measure(pid, a.secs), "pipOpen": opened}); safe(keeper)
            if how == "meet-left":
                sv.ev(call, "leave()")
                until(lambda: not tab(call)["onCall"])
            else:
                sv.sp("closeTab", id=call)
            time.sleep(2)
            for r in range(a.rounds):
                st = sv.cmd({"do": "meetpip"})
                emit(f"{how}-{r}", {**measure(pid, a.secs), "pipWindows": len(st["windows"])}); safe(keeper)
            if how == "meet-left":
                # Then its tab closed too: whatever the page left running goes.
                sv.sp("closeTab", id=call)
                time.sleep(2)
                emit(f"{how}-then-closed", measure(pid, a.secs)); safe(keeper)
            stop(keeper)
        keeper = None
    finally:
        if keeper:
            keeper.stop = True
        sv.finish()
        if work:
            subprocess.run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                            "-u", sv.APP], capture_output=True)
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
