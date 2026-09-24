#!/usr/bin/env python3
"""Exercise browser appearance and actual WebKit rendering in a disposable app.

Build with `swift build`, then run `python3 tests/compact-bars.py`.
Each run creates its own app, preferences and profile. No existing profile is reused.
"""

import datetime
import hashlib
import html
import json
import os
from pathlib import Path
import plistlib
import runpy
import shutil
import socket
import subprocess
import tempfile
import time
import uuid
from http.server import BaseHTTPRequestHandler


ROOT = Path(__file__).resolve().parents[1]
BENCH = runpy.run_path(str(ROOT / "bench"))


class PageHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        label = html.escape(self.path)
        body = (f'<!doctype html><title>Appearance: {label}</title>'
                f'<h1>Appearance integration test</h1><p id="identity">{label}</p>'
                '<a id="popup" href="/popup" target="_blank">Open another tab</a>').encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


class Run:
    def __init__(self, args, origin):
        self.args = args
        self.origin = origin
        self.directory = Path(tempfile.mkdtemp(prefix="search-appearance-"))
        self.profile = Path(BENCH["folder"](args.world))
        self.socket_path = str(self.profile / "bench.sock")
        if self.profile.exists():
            raise RuntimeError(f"refusing existing probe profile: {self.profile}")
        if len(self.socket_path.encode()) >= 104:
            raise RuntimeError("world name is too long for the Unix socket")
        self.suite = "com.officecommun.search.test." + args.world
        self.app = self.directory / "Search Appearance Test.app"
        self.process = None
        self.log = None
        self.report = {"world": args.world, "directory": str(self.directory),
                       "profile": str(self.profile), "checks": []}

    def check(self, condition, message):
        self.report["checks"].append({"ok": bool(condition), "message": message})
        print(("PASS " if condition else "FAIL ") + message, flush=True)
        if not condition:
            raise AssertionError(message)

    def ask(self, verb, **fields):
        result = BENCH["ask"](self.socket_path, {"do": verb, **fields})
        if "error" in result:
            raise RuntimeError(f"{verb}: {result['error']}")
        return result

    def organize(self, action="save", **fields):
        assert action == "save"
        return self.ask("native", action="save")

    def js(self, tab, script):
        return self.ask("eval", id=tab, js=script).get("value")

    def page(self, tab, path):
        deadline = time.monotonic() + 20
        last = None
        while time.monotonic() < deadline:
            try:
                last = self.js(tab, "({path:location.pathname, ready:document.readyState, "
                              "identity:document.querySelector('#identity')?.textContent})")
                if last and last.get("path") == path and last.get("ready") == "complete":
                    self.check(last.get("identity") == path, "real DOM loaded: " + path)
                    return
            except RuntimeError:
                pass
            time.sleep(0.1)
        raise AssertionError(f"page never loaded {path}: {last}")

    def open(self, path):
        self.ask("bookmark", new=True, url=self.origin + path)
        tab = next(t["id"] for t in self.ask("tabs")["tabs"] if t["active"])
        self.page(tab, path)
        return tab

    def restored(self, path):
        return next(t["id"] for t in self.ask("tabs")["tabs"] if t["url"] == self.origin + path)

    def prepare(self):
        binary = Path(self.args.binary).resolve()
        if not binary.is_file():
            raise RuntimeError("run swift build first")
        executable = self.app / "Contents/MacOS/Search"
        executable.parent.mkdir(parents=True)
        shutil.copy2(binary, executable)
        self.report["binarySha256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
        plist_path = self.app / "Contents/Info.plist"
        info = {"CFBundleIdentifier": "com.officecommun.search.appearance-test." + uuid.uuid4().hex,
                "CFBundleExecutable": "Search", "CFBundleName": "Search Appearance Test",
                "CFBundlePackageType": "APPL", "NSHighResolutionCapable": True}
        # This test copy must never register itself as a candidate default browser.
        info.pop("CFBundleURLTypes", None)
        info.pop("CFBundleDocumentTypes", None)
        plist_path.write_bytes(plistlib.dumps(info))
        subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(self.app)],
                       check=True, capture_output=True)
        self.report["bundleID"] = info["CFBundleIdentifier"]
        self.profile.mkdir(parents=True)
        (self.profile / "session.json").write_text(json.dumps({
            "tabs": [
                {"url": self.origin + "/legacy-pin", "title": "Legacy pin", "pin": "Legacy"},
                {"url": self.origin + "/legacy-selected", "title": "Legacy selected"},
                {"url": self.origin + "/legacy-last", "title": "Legacy last"},
            ], "active": 1,
        }))
        prefs = self.directory / "prefs.plist"
        prefs.write_bytes(plistlib.dumps({"bench": True, "welcomed": True,
            "update.checked": datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)}))
        subprocess.run(["defaults", "import", self.suite, str(prefs)], check=True, capture_output=True)

    def launch(self):
        self.log = (self.directory / "app.log").open("ab")
        self.process = subprocess.Popen([str(self.app / "Contents/MacOS/Search")],
            env={**os.environ, "SEARCH_PROBE": self.args.world}, stdout=self.log, stderr=self.log,
            start_new_session=True)
        self.report["pid"] = self.process.pid
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError(f"owned app exited with {self.process.returncode}; see app.log")
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                    connection.connect(self.socket_path)
                self.ask("tabs")
                subprocess.run(["open", str(self.app)], check=True)
                time.sleep(.5)
                return
            except (OSError, ValueError, SystemExit):
                time.sleep(0.1)
        raise RuntimeError("owned app never opened its bench socket")

    def stop(self):
        if self.process and self.process.poll() is None:
            # Only the subprocess launched above is eligible for termination.
            self.process.terminate()
            self.process.wait(timeout=15)
        if self.log:
            self.log.close()
            self.log = None
