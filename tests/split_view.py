#!/usr/bin/env python3
"""Offline regression checks for Split View through Search's real Browser model.

Run with `python3 tests/split_view.py`. The runner builds a uniquely identified
debug app bundle and SEARCH_PROBE world, starts only that executable, and serves
all test pages and the updater feed from localhost.
"""

from __future__ import annotations

import json
import os
import plistlib
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / ".build"
FIRST_SPACE = "00000000-0000-0000-0000-000000000001"


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path == "/appcast.json":
            body = json.dumps({
                "version": "0.0.0",
                "build": 0,
                "url": f"http://127.0.0.1:{self.server.server_port}/Search.zip",
                "dmg": f"http://127.0.0.1:{self.server.server_port}/Search.dmg",
            }).encode()
            kind = "application/json"
        else:
            name = self.path.strip("/").split("?", 1)[0] or "page"
            title = name.replace("-", " ").title()
            body = (
                "<!doctype html><meta charset=utf-8>"
                f"<title>{title}</title><h1>{title}</h1><textarea id='split-draft'>fixture</textarea>"
                f"<a href='/linked'>linked</a>"
            ).encode()
            kind = "text/html; charset=utf-8"
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_: object) -> None:
        pass


class Runner:
    def __init__(self) -> None:
        self.world = "split-test-" + uuid.uuid4().hex[:10]
        self.bundle_id = f"com.officecommun.search.splitrunner.{self.world}"
        self.bundle = BUILD / f"SplitViewTests-{self.world}.app"
        self.executable = self.bundle / "Contents" / "MacOS" / "Search"
        self.suite = f"com.officecommun.search.test.{self.world}"
        self.support = Path.home() / "Library" / "Application Support" / f"Search ({self.world})"
        self.log_path = BUILD / f"split-view-{self.world}.log"
        self.log_file = None
        self.process: subprocess.Popen[bytes] | None = None
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
        self.server_thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.port = self.server.server_port
        self.feed = f"http://127.0.0.1:{self.port}/appcast.json"
        self.socket_path = self.support / "bench.sock"
        self.passed = 0
        self.failed = 0

    def build(self) -> None:
        BUILD.mkdir(parents=True, exist_ok=True)
        developer = subprocess.check_output(["/usr/bin/xcode-select", "-p"], text=True).strip()
        swift = Path(developer) / "Toolchains" / "XcodeDefault.xctoolchain" / "usr" / "bin" / "swift"
        sdk = subprocess.check_output(
            ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True
        ).strip()
        build_env = os.environ.copy()
        build_env["SDKROOT"] = sdk
        subprocess.run(
            [str(swift), "build", "--package-path", str(ROOT), "--sdk", sdk],
            check=True, env=build_env,
        )
        binary = ROOT / ".build" / "debug" / "Search"
        if not binary.is_file():
            raise RuntimeError(f"debug binary was not built: {binary}")
        contents = self.bundle / "Contents"
        (contents / "MacOS").mkdir(parents=True, exist_ok=True)
        shutil.copy2(binary, self.executable)
        info = {
            "CFBundleName": "Split View Tests",
            "CFBundleDisplayName": "Split View Tests",
            "CFBundleExecutable": "Search",
            "CFBundleIdentifier": self.bundle_id,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0.3",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "14.0",
            "NSPrincipalClass": "NSApplication",
        }
        with (contents / "Info.plist").open("wb") as stream:
            plistlib.dump(info, stream)
        subprocess.run(["/usr/bin/defaults", "write", self.suite, "bench", "-bool", "true"], check=True)
        subprocess.run(["/usr/bin/defaults", "write", self.suite, "welcomed", "-bool", "true"], check=True)
        subprocess.run(["/usr/bin/defaults", "write", self.suite, "spaces", "-bool", "true"], check=True)
        subprocess.run(["/usr/bin/defaults", "write", self.suite, "tabs.sleep", "-bool", "false"], check=True)

    def start(self) -> None:
        env = os.environ.copy()
        env["SEARCH_PROBE"] = self.world
        env["SEARCH_FEED"] = self.feed
        self.log_file = self.log_path.open("ab")
        self.process = subprocess.Popen(
            [str(self.executable)], env=env, cwd=ROOT,
            stdout=self.log_file, stderr=subprocess.STDOUT, start_new_session=True,
        )
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError(f"test app exited with {self.process.returncode}; see {self.log_path}")
            if self.socket_path.exists():
                try:
                    self.request("state")
                    return
                except (FileNotFoundError, ConnectionRefusedError, TimeoutError):
                    pass
            time.sleep(0.1)
        raise TimeoutError(f"test app did not open its bench socket; see {self.log_path}")

    def stop(self) -> None:
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        self.process = None
        if self.log_file:
            self.log_file.close()
            self.log_file = None

    def command(self, request: dict[str, Any]) -> dict[str, Any]:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(30)
            client.connect(str(self.socket_path))
            client.sendall(json.dumps(request).encode() + b"\n")
            chunks = []
            while True:
                chunk = client.recv(65536)
                if not chunk:
                    break
                chunks.append(chunk)
        answer = json.loads(b"".join(chunks).split(b"\n", 1)[0] or b"{}")
        if "error" in answer:
            raise RuntimeError(f"{request.get('do')} {request.get('action', '')}: {answer['error']}")
        return answer

    def request(self, action: str, **fields: Any) -> dict[str, Any]:
        return self.command({"do": "split", "action": action, **fields})

    def evaluate(self, tab_id: str, javascript: str) -> Any:
        return self.command({"do": "eval", "id": tab_id, "js": javascript}).get("value")

    def expect(self, name: str, condition: bool) -> None:
        if condition:
            self.passed += 1
            print(f"PASS {name}")
        else:
            self.failed += 1
            print(f"FAIL {name}")

    def page(self, name: str, *, from_id: str | None = None, foreground: bool = True, at_end: bool = False) -> str:
        args: dict[str, Any] = {
            "url": f"http://127.0.0.1:{self.port}/{name}",
            "foreground": foreground,
            "atEnd": at_end,
        }
        if from_id is not None:
            args["from"] = from_id
        return self.request("open", **args)["resultID"]

    def state(self) -> dict[str, Any]:
        return self.request("state")

    def tab(self, state: dict[str, Any], tab_id: str) -> dict[str, Any]:
        return next(tab for tab in state["tabs"] if tab["id"] == tab_id)

    def index(self, state: dict[str, Any], tab_id: str) -> int:
        return next(i for i, tab in enumerate(state["tabs"]) if tab["id"] == tab_id)

    def session_path(self, space_id: str) -> Path:
        name = "session.json" if space_id == FIRST_SPACE else f"session-{space_id}.json"
        return self.support / name

    def session(self, space_id: str) -> dict[str, Any]:
        path = self.session_path(space_id)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and not path.exists():
            time.sleep(0.05)
        return json.loads(path.read_text())

    def run(self) -> None:
        self.server_thread.start()
        self.build()
        self.start()

        self.expect("Split View is off in a fresh test world", not self.state()["enabled"])
        self.request("enabled", on=True)

        state = self.state()
        initial = next(tab["id"] for tab in state["tabs"] if tab["blank"] and not tab["shy"])
        a = self.page("a")
        b = self.page("b")
        c = self.page("c")
        self.request("close", id=initial)

        self.command({"do": "wait", "id": a, "seconds": 15})
        self.request("select", id=a)
        prepared = self.evaluate(a, "(() => { window.__splitMarker = 'split-state-survives'; document.querySelector('#split-draft').value = 'typed before pairing'; return 'ready'; })()")
        self.expect("page fixture accepts live WebView state", prepared == "ready")

        # Drop ordering is tested through Browser.pair, the same operation used
        # by both the left and right drop zones.
        state = self.request("pair", id=b, **{"with": a}, side="left")
        pair = state["splits"][-1]
        self.expect("drop right tab onto left side preserves order", pair["left"] == b and pair["right"] == a)
        self.expect("paired tabs render as one strip item", b in state["displayedIDs"] and a not in state["displayedIDs"])
        self.expect("both paired pages are visible", set(state["visibleIDs"]) == {a, b})
        state = self.request("drop", id=b, before=a)
        self.expect("dropping a paired tab onto itself or its partner is a no-op", len(state["splits"]) == 1 and state["splits"][0]["left"] == b and state["splits"][0]["right"] == a)
        state = self.request("drop", id=a, before=b)
        self.expect("the other half also cannot be dropped onto its partner", len(state["splits"]) == 1 and state["splits"][0]["left"] == b and state["splits"][0]["right"] == a)

        state = self.request("focus", id=a)
        self.expect("focus moves within the pair without changing visible pages", state["activeID"] == a and set(state["visibleIDs"]) == {a, b})
        preserved = self.evaluate(a, "window.__splitMarker + '|' + document.querySelector('#split-draft').value")
        self.expect("split and focus preserve the same page DOM and JavaScript state", preserved == "split-state-survives|typed before pairing")
        slept = self.request("sleep", id=b)
        self.expect("unfocused visible pane is protected from sleep", slept.get("sleepResult") == "on screen" and not self.tab(slept, b)["asleep"])

        state = self.request("select", id=c)
        self.expect("selecting an independent tab leaves the pair intact", len(state["splits"]) == 1 and state["activeID"] == c and state["visibleIDs"] == [c])
        self.request("select", id=a)
        preserved = self.evaluate(a, "window.__splitMarker + '|' + document.querySelector('#split-draft').value")
        self.expect("returning to a split page preserves its DOM and JavaScript state", preserved == "split-state-survives|typed before pairing")

        # Reverse the drop direction, then detach and close each side in turn.
        state = self.request("pair", id=b, **{"with": a}, side="right")
        pair = state["splits"][-1]
        self.expect("drop left tab onto right side preserves order", pair["left"] == a and pair["right"] == b)
        state = self.request("detach", id=b)
        self.expect("detaching keeps both original tabs", not state["splits"] and {a, b}.issubset({tab["id"] for tab in state["tabs"]}))
        preserved = self.evaluate(a, "window.__splitMarker + '|' + document.querySelector('#split-draft').value")
        self.expect("detaching the pair preserves the existing page", preserved == "split-state-survives|typed before pairing")
        state = self.request("pair", id=b, **{"with": a}, side="left")
        state = self.request("close", id=b)
        self.expect("closing left pane removes only that tab and split", all(tab["id"] != b for tab in state["tabs"]) and a in {tab["id"] for tab in state["tabs"]} and not state["splits"])

        b = self.page("b-again")
        state = self.request("pair", id=b, **{"with": a}, side="right")
        state = self.request("close", id=b)
        self.expect("closing right pane keeps the left tab", all(tab["id"] != b for tab in state["tabs"]) and a in {tab["id"] for tab in state["tabs"]} and not state["splits"])

        b = self.page("b-third")
        state = self.request("pair", id=b, **{"with": a}, side="left")
        pair = state["splits"][-1]
        # A page opened from either member should land after the group's right
        # edge, while leaving the source page selected.
        linked = self.page("linked-from-pane", from_id=a, foreground=False)
        state = self.state()
        self.expect("new page from a paired tab lands after the whole pair", self.index(state, linked) == self.index(state, pair["right"]) + 1)

        state = self.request("drop", id=a, before=c)
        self.expect("dropping one half before an outside tab detaches it in that order", not state["splits"] and self.index(state, b) < self.index(state, linked) < self.index(state, a) < self.index(state, c))
        state = self.request("pair", id=b, **{"with": a}, side="left")
        state = self.request("drop", id=a)
        self.expect("dropping one half into the strip detaches but keeps both tabs", not state["splits"] and {a, b}.issubset({tab["id"] for tab in state["tabs"]}) and state["tabs"][-1]["id"] == a)
        state = self.request("pair", id=b, **{"with": a}, side="left")

        # Move a standalone tab from before the pair onto each raw member index.
        # Browser.move must treat either half as the pair's displayed item.
        state = self.request("move", id=linked, to=0)
        state = self.request("move", id=linked, to=self.index(state, b))
        moved_pair = next((item for item in state["splits"] if {item["left"], item["right"]} == {a, b}), None)
        self.expect("moving a tab before onto split.left preserves adjacency", moved_pair is not None and self.index(state, moved_pair["right"]) == self.index(state, moved_pair["left"]) + 1)
        state = self.request("move", id=linked, to=0)
        state = self.request("move", id=linked, to=self.index(state, a))
        moved_pair = next((item for item in state["splits"] if {item["left"], item["right"]} == {a, b}), None)
        self.expect("moving a tab before onto split.right preserves adjacency", moved_pair is not None and self.index(state, moved_pair["right"]) == self.index(state, moved_pair["left"]) + 1)

        # Moving the right member represents the whole group in the tab row.
        pair = moved_pair
        state = self.request("move", id=pair["right"], to=self.index(state, linked))
        moved_pair = next((item for item in state["splits"] if {item["left"], item["right"]} == {a, b}), None)
        self.expect("moving from split.right moves the whole pair", moved_pair is not None and self.index(state, moved_pair["right"]) == self.index(state, moved_pair["left"]) + 1 and self.index(state, moved_pair["left"]) > self.index(state, linked))

        # A stale close index can land exactly on a split's right member.
        # Both reopen and the Little-window insert path must skip past the pair.
        pair = moved_pair
        seam_ghost = self.page("restore-seam", from_id=pair["right"], foreground=False)
        state = self.request("close", id=seam_ghost)
        pair = next(item for item in state["splits"] if {item["left"], item["right"]} == {a, b})
        prior = self.request("insert", url=f"http://127.0.0.1:{self.port}/insert-before-pair", index=self.index(state, pair["left"]))
        state = prior
        pair = next(item for item in state["splits"] if {item["left"], item["right"]} == {a, b})
        self.expect("insert before a pair keeps both members adjacent", self.index(state, pair["right"]) == self.index(state, pair["left"]) + 1)
        seam_insert = self.request("insert", url=f"http://127.0.0.1:{self.port}/insert-at-seam", index=self.index(state, pair["right"]))
        state = seam_insert
        pair = next(item for item in state["splits"] if {item["left"], item["right"]} == {a, b})
        self.expect("inserting at the right-member seam goes after the pair", self.index(state, seam_insert["resultID"]) > self.index(state, pair["right"]) and self.index(state, pair["right"]) == self.index(state, pair["left"]) + 1)
        state = self.request("reopen")
        pair = next(item for item in state["splits"] if {item["left"], item["right"]} == {a, b})
        self.expect("reopening at the saved right-member seam goes after the pair", self.index(state, state["activeID"]) > self.index(state, pair["right"]) and self.index(state, pair["right"]) == self.index(state, pair["left"]) + 1)

        # Separate the pair before creating the paired-blank/new-tab case.
        state = self.request("detach", id=b)
        self.request("focus", id=a)
        state = self.request("start")
        blank_pair = state["splits"][-1]
        paired_blank = blank_pair["right"]
        state = self.request("newTab")
        new_blank = state["activeID"]
        self.expect("new tab does not reuse a blank pane already in a pair", paired_blank != new_blank and self.tab(state, paired_blank)["blank"] and self.tab(state, new_blank)["blank"] and all(new_blank not in (item["left"], item["right"]) for item in state["splits"]))
        self.request("close", id=new_blank)

        # A private group and a bench page are deliberately present while the
        # real session writer runs. Neither may be serialized.
        self.request("private")
        private = self.state()["activeID"]
        state = self.request("pair", id=private, **{"with": a}, side="left")
        self.expect("ordinary and private tabs cannot form a split", len(state["splits"]) == 1 and self.tab(state, private)["shy"] and not self.tab(state, a)["shy"])
        private_page = self.page("private-page")
        state = self.request("start")
        private_pair = state["splits"][-1]
        bench = self.request("bench", url=f"http://127.0.0.1:{self.port}/bench-only")["resultID"]
        before_bench_pair = len(state["splits"])
        state = self.request("pair", id=bench, **{"with": a}, side="left")
        self.expect("bench tabs cannot form a split", len(state["splits"]) == before_bench_pair and self.tab(state, bench)["bench"])
        active_public = self.page("active-after-filter", from_id=a, at_end=True)
        state = self.request("save")
        self.expect("private and bench tabs are present only in the live model", self.tab(state, private)["shy"] and self.tab(state, private_page)["shy"] and self.tab(state, bench)["bench"])
        personal = self.session(FIRST_SPACE)
        saved_urls = [entry["url"] for entry in personal["tabs"]]
        self.expect("session excludes private and bench page URLs", not any("private-page" in url or "bench-only" in url for url in saved_urls))
        saved_splits = personal.get("splits", [])
        saved_split_urls = [saved_urls[index] for pair in saved_splits for index in (pair["left"], pair["right"]) if 0 <= index < len(saved_urls)]
        self.expect("session keeps ordinary splits while excluding private groups", bool(saved_splits) and len(saved_split_urls) == 2 * len(saved_splits) and not any("private" in url for url in saved_split_urls))
        active_index = personal.get("active", -1)
        live_state = self.state()
        active_url = self.tab(live_state, active_public)["url"]
        self.expect("public page was opened after private and bench entries", self.index(live_state, active_public) == len(live_state["tabs"]) - 1)
        self.expect("saved active index is remapped to the selected public page", 0 <= active_index < len(saved_urls) and saved_urls[active_index] == active_url)

        # Space one is committed on switch. Give space two its own split, then
        # verify the files, parked in-memory row, and both rows after relaunch.
        self.request("space", spaceAction="new", name="Split regression")
        second = self.state()["spaceID"]
        space_page = self.page("space-two")
        state = self.request("start")
        second_pair = state["splits"][-1]
        second_fraction = 0.41
        state = self.request("fraction", split=second_pair["id"], fraction=second_fraction)
        state = self.request("fraction", split=second_pair["id"], fraction=1.25)
        self.expect("split ratio clamps to its maximum", abs(state["splits"][-1]["fraction"] - 0.8) < 0.001)
        state = self.request("fraction", split=second_pair["id"], fraction=-0.25)
        self.expect("split ratio clamps to its minimum", abs(state["splits"][-1]["fraction"] - 0.2) < 0.001)
        state = self.request("fraction", split=second_pair["id"], fraction=second_fraction)
        self.request("save")
        second_session = self.session(second)
        second_file_pair = second_session["splits"][-1]
        self.expect("each Space has a separate saved session", self.session_path(FIRST_SPACE) != self.session_path(second) and self.session_path(FIRST_SPACE).exists() and self.session_path(second).exists())
        self.expect("split ratio and blank pane are persisted per Space", abs(second_file_pair["fraction"] - second_fraction) < 0.001 and any(entry["url"] == "about:blank" for entry in second_session["tabs"]))

        state = self.request("space", spaceAction="go", spaceID=FIRST_SPACE)
        self.expect("switching Spaces preserves the first Space's live pair", state["spaceID"] == FIRST_SPACE and bool(state["splits"]))
        state = self.request("space", spaceAction="go", spaceID=second)
        self.expect("switching back preserves the second Space's live pair", state["spaceID"] == second and any(abs(pair["fraction"] - second_fraction) < 0.001 for pair in state["splits"]))

        self.stop()
        damaged = self.session(second)
        orphan = len(damaged["tabs"])
        damaged["tabs"].append({"url": "about:blank", "title": ""})
        damaged["splits"].append({"left": 999, "right": orphan, "fraction": 0.5})
        self.session_path(second).write_text(json.dumps(damaged))
        self.start()
        state = self.state()
        restored = next((pair for pair in state["splits"] if abs(pair["fraction"] - second_fraction) < 0.001), None)
        self.expect("relaunch restores the current Space's split and ratio", state["spaceID"] == second and restored is not None)
        self.expect("invalid saved split and orphan blank are discarded", len(state["splits"]) == 1 and
                    sum(tab["blank"] for tab in state["tabs"]) == 1)
        if restored:
            right = self.tab(state, restored["right"])
            self.expect("relaunch restores a blank right pane", right["blank"])

        state = self.request("space", spaceAction="go", spaceID=FIRST_SPACE)
        self.expect("relaunch also restores the other Space's saved split", state["spaceID"] == FIRST_SPACE and bool(state["splits"]) and all(not tab["shy"] for tab in state["tabs"]))

        # A folded group still exposes the left representative when focus is
        # in the right pane; row navigation skips the other pane of the pair.
        pair = state["splits"][0]
        left, right = pair["left"], pair["right"]
        state = self.request("group", id=left)
        group_id = state["groups"][-1]["id"]
        self.request("group", id=right, group=group_id)
        state = self.request("pair", id=right, **{"with": left}, side="right")
        state = self.request("focus", id=right)
        state = self.request("collapse", group=group_id)
        self.expect("collapsed group shows pair representative for focused right pane", left in state["shownIDs"] and right not in state["shownIDs"])
        state = self.request("step", direction=-1)
        self.expect("previous tab skips both panes of the pair", state["activeID"] not in (left, right))

        # Moving one pane to another Space or window leaves the partner in a
        # valid ordinary tab and never serializes a stale pair.
        self.request("focus", id=right)
        state = self.request("moveSpace", id=right, spaceID=second)
        self.expect("moving a pane to another Space separates its pair", all(right not in (p["left"], p["right"]) for p in state["splits"]))
        state = self.request("space", spaceAction="go", spaceID=second)
        self.expect("moved pane arrives in target Space", right in {t["id"] for t in state["tabs"]})
        other = next(t["id"] for t in state["tabs"] if "space-two" in t["url"])
        state = self.request("pair", id=right, **{"with": other}, side="left")
        self.expect("moved pane can form a new pair in target Space", any(right in (p["left"], p["right"]) for p in state["splits"]))
        state = self.request("moveWindow", id=right)
        self.expect("moving pane to new window separates pair and keeps partner", state["windows"] >= 2 and not state["splits"] and other in {t["id"] for t in state["tabs"]})
        self.command({"do": "windows", "action": "new"})
        blank_window = self.request("start", window=3)
        blank_pair = blank_window["splits"][-1]
        self.request("moveWindow", window=2, id=right, targetWindow=3)
        received = self.request("state", window=3)
        present = {t["id"] for t in received["tabs"]}
        self.expect("receiving a tab preserves an empty target-window split", right in present and
                    blank_pair["left"] in present and blank_pair["right"] in present and
                    any(p["left"] == blank_pair["left"] and p["right"] == blank_pair["right"] for p in received["splits"]))
        self.request("space", spaceAction="go", spaceID=FIRST_SPACE)
        state = self.request("enabled", on=False)
        self.expect("turning Split View off detaches every visible pair", not state["splits"] and not state["enabled"])
        rows = self.request("rows")["rows"]
        self.expect("turning Split View off clears parked and saved Space pairs", all(row["splits"] == 0 for row in rows.values()))

        print(f"\n{self.passed} passed, {self.failed} failed; isolated world {self.world}")
        print(f"log: {self.log_path}")
        if self.failed:
            raise SystemExit(1)

    def interactive(self) -> None:
        self.server_thread.start()
        self.build()
        self.start()
        self.request("enabled", on=True)
        initial = next((tab["id"] for tab in self.state()["tabs"] if tab["blank"]), None)
        first = self.page("split-left")
        second = self.page("split-right")
        self.page("single-tab")
        if initial:
            self.request("close", id=initial)
        self.request("pair", id=first, **{"with": second}, side="left")
        self.request("select", id=first)
        self.command({"do": "window"})
        print(json.dumps({
            "bundle": str(self.bundle), "bundleID": self.bundle_id,
            "world": self.world, "fixture": f"http://127.0.0.1:{self.port}/",
            "socket": str(self.socket_path), "log": str(self.log_path),
            "state": self.state(),
        }, indent=2), flush=True)
        print("Isolated Split View app is open; stop this process to clean up.", flush=True)
        while self.process and self.process.poll() is None:
            time.sleep(0.5)

    def close(self) -> None:
        self.stop()
        self.server.shutdown()
        self.server.server_close()


def main() -> int:
    runner = Runner()
    try:
        if "--interactive" in sys.argv[1:]:
            runner.interactive()
        else:
            runner.run()
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        return 130
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr)
        print(f"log: {runner.log_path}", file=sys.stderr)
        return 1
    finally:
        runner.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
