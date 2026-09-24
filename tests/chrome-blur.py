#!/usr/bin/env python3
"""Regression: blur must change a background filter, never backdrop opacity."""
import argparse
import json
from pathlib import Path
import runpy
import subprocess
import threading
import time
import uuid
from http.server import ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
HELPERS = runpy.run_path(str(ROOT / "tests/chrome_support.py"))
server = ThreadingHTTPServer(("127.0.0.1", 0), HELPERS["PageHandler"])
threading.Thread(target=server.serve_forever, daemon=True).start()
run = HELPERS["Run"](argparse.Namespace(binary=str(ROOT / ".build/debug/Search"),
                                     world="blur-" + uuid.uuid4().hex[:8]),
                     f"http://127.0.0.1:{server.server_port}")
try:
    run.prepare()
    for key, value in [("chrome.transparency", 0.8), ("chrome.blur", 1)]:
        subprocess.run(["defaults", "write", run.suite, key, "-float", str(value)], check=True)
    run.launch()
    tab = run.open("/blur-regression")
    run.ask("resize", width=1180, height=780)
    run.js(tab, "document.body.style.background = 'repeating-linear-gradient(90deg, #ee4433 0 24px, #2255cc 24px 48px)'; document.body.style.minHeight = '2000px'; true")
    time.sleep(0.6)
    backdrop = run.ask("native", action="hit-test", x=700, y=300)["backdrops"][0]
    run.report["backdrop"] = backdrop
    run.check(backdrop["alpha"] == 1, "blur leaves background opacity unchanged")
    run.check(any(f["name"] == "CIGaussianBlur" and f["radius"] > 0 for f in backdrop["filters"]),
              "blur applies a Gaussian filter to the actual background view")
    def capture(name, rects):
        image_path = run.directory / (name + ".png")
        run.ask("native", action="composited-shot", path=str(image_path), contrastRects=rects)
        status = Path(str(image_path) + ".json")
        deadline = time.monotonic() + 10
        while not status.exists() and time.monotonic() < deadline:
            time.sleep(0.1)
        result = json.loads(status.read_text())
        run.check("error" not in result, "composited app window is captured: " + name)
        return result["contrast"]

    page, bar = capture("blur-composited", [[850, 180, 150, 8], [850, 20, 150, 8]])
    run.report["contrast"] = {"page": page, "bar": bar}
    run.check(page > 30 and bar < page * 0.3,
              "rendered bar softens page stripes instead of merely fading them")
    run.ask("ui", sidebar=True)
    time.sleep(0.6)
    page, side = capture("sidebar-blur-composited", [[850, 500, 150, 8], [30, 500, 150, 8]])
    run.report["sidebarContrast"] = {"page": page, "sidebar": side}
    run.check(page > 30 and side < page * 0.3,
              "rendered sidebar blurs the webpage underneath it")
    run.report["ok"] = True
except BaseException as error:
    run.report.update(ok=False, error=str(error))
    raise
finally:
    run.stop()
    server.shutdown()
    server.server_close()
    report = run.directory / "blur-regression.json"
    report.write_text(json.dumps(run.report, indent=2))
    print(f"Report: {report}", flush=True)
