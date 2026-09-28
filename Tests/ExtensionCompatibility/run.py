#!/usr/bin/env python3
"""Run the account-free MV3 compatibility fixture in a private Search world."""

import json
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "build" / "Search.app"
BENCH = ROOT / "bench"
FIXTURE = Path(__file__).resolve().parent / "extension"


def command(args, *, timeout=30, check=True):
    result = subprocess.run(args, text=True, capture_output=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f"{args}: {result.stderr.strip() or result.stdout.strip()}")
    return result


def main():
    if sys.platform != "darwin":
        raise RuntimeError("This integration fixture runs on macOS only")
    if not APP.is_dir():
        raise RuntimeError("build/Search.app is missing; build Search first")

    token = uuid.uuid4().hex[:12]
    world = f"extcompat-{token}"
    bundle_id = f"com.officecommun.search.extcompat.{token}"
    suite = f"com.officecommun.search.test.{world}"
    support = Path.home() / "Library" / "Application Support" / f"Search ({world})"
    webkit = Path.home() / "Library" / "WebKit" / bundle_id
    if support.exists() or webkit.exists():
        raise RuntimeError("Random fixture world already exists; retry the runner")

    temporary = Path(tempfile.mkdtemp(prefix="search-extension-compat-"))
    clone = temporary / "Search-ExtensionCompatibility.app"
    launch_requested = False
    app_started = False
    tab_id = None
    extension_id = None
    safe_to_remove = True

    def bench(*args, check=True):
        return command([str(BENCH), "--world", world, *map(str, args)], check=check).stdout.strip()

    try:
        # A distinct bundle uses a distinct WebKit container; SEARCH_PROBE
        # still gives this run a named profile and the bench socket.
        shutil.copytree(APP, clone)
        info_path = clone / "Contents" / "Info.plist"
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)
        info["CFBundleIdentifier"] = bundle_id
        with info_path.open("wb") as handle:
            plistlib.dump(info, handle, fmt=plistlib.FMT_BINARY)
        command(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(clone)], timeout=120)

        command(["/usr/bin/defaults", "write", suite, "bench", "-bool", "true"])
        command(["/usr/bin/defaults", "write", suite, "passkeys", "-bool", "false"])
        command(["/usr/bin/open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={world}", str(clone)])
        launch_requested = True

        startup_deadline = time.monotonic() + 30
        while time.monotonic() < startup_deadline:
            result = command([str(BENCH), "--world", world, "tabs"], check=False)
            if result.returncode == 0:
                app_started = True
                break
            time.sleep(0.2)
        if not app_started:
            raise RuntimeError("private Search world did not start its bench socket")

        bench("ext-folder", FIXTURE, "--yes")
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            listing = json.loads(bench("extensions"))
            fixture = next((item for item in listing.get("extensions", [])
                            if item.get("name") == "Search Extension Compatibility Fixture"), None)
            if fixture and fixture.get("loaded") and not listing.get("busy"):
                extension_id = fixture["id"]
                break
            time.sleep(0.2)
        if not extension_id:
            raise RuntimeError(f"fixture extension did not load: {listing}")

        tab_id = bench("ext-page", extension_id, "harness.html")
        bench("wait", tab_id, "20")
        deadline = time.monotonic() + 60
        result = None
        while time.monotonic() < deadline:
            raw = bench("eval", tab_id, "JSON.stringify(window.__fixtureResult)")
            if raw and raw not in ("null", "undefined"):
                result = json.loads(raw)
                break
            time.sleep(0.25)
        if result is None:
            raise RuntimeError("fixture did not finish within 60 seconds")
        evidence = Path(tempfile.gettempdir()) / f"search-extension-compat-{world}.json"
        report = {"world": world, "bundleId": bundle_id, **result}
        evidence.write_text(json.dumps(report, indent=2) + "\n")
        checks = report.get("checks", [])
        summary = {
            "world": world,
            "bundleId": bundle_id,
            "ok": report.get("ok"),
            "passedChecks": sum(1 for check in checks if check.get("ok")),
            "failedChecks": [
                {"label": check.get("label"), "detail": check.get("detail")}
                for check in checks if not check.get("ok")
            ],
            "requestDeliveries": len(report.get("received", [])),
            "removedPageNotices": report.get("removedEvents", []),
            "workerRemovedCounts": (report.get("finalState") or {}).get("removed", []),
            "error": report.get("error"),
            "evidenceLog": str(evidence),
        }
        print(json.dumps(summary, indent=2))
        if not result.get("ok"):
            return 1
        return 0
    finally:
        if launch_requested:
            if app_started and tab_id:
                bench("close", tab_id, check=False)
            if app_started and extension_id:
                bench("ext-remove", extension_id, check=False)
            quit_result = command([str(BENCH), "--world", world, "quit"], check=False)
            if quit_result.returncode == 0:
                # Wait for the process to stop responding before deleting its
                # private profile or copied executable; never signal by name.
                for _ in range(80):
                    if command([str(BENCH), "--world", world, "tabs"], check=False).returncode:
                        break
                    time.sleep(0.1)
                else:
                    safe_to_remove = False
            else:
                safe_to_remove = False
        if safe_to_remove:
            shutil.rmtree(support, ignore_errors=True)
            shutil.rmtree(webkit, ignore_errors=True)
            command(["/usr/bin/defaults", "delete", suite], check=False)
            shutil.rmtree(temporary, ignore_errors=True)
        else:
            print(f"Search did not confirm shutdown; preserved its private files at {temporary}", file=sys.stderr)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"Extension compatibility fixture failed: {error}", file=sys.stderr)
        raise SystemExit(1)
