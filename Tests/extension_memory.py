#!/usr/bin/env python3
"""Check extension script sharing in a built app, including its startup.

Run after ./build.sh debug: python3 Tests/extension_memory.py [Search.app]
Uses the existing hidden, disposable probe harness and local pages only.
The old implementation retains hundreds of MiB for 32 copies of the same
script/style in four tabs. The bound allows 96 MiB of incidental growth.
"""
import json
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import split_view as sv

sv.use("extension-memory")
if len(sys.argv) > 1:
    sv.APP = str(Path(sys.argv[1]).resolve())


def footprint():
    pid, = sv.pids()
    output = subprocess.check_output(["vmmap", "-summary", pid], text=True)
    value, unit = re.search(r"^Physical footprint:\s*([\d.]+)([KMG])", output, re.M).groups()
    return float(value) * {"K": 1 / 1024, "M": 1, "G": 1024}[unit]


def loaded(enabled):
    for _ in range(100):
        extensions = sv.cmd({"do": "extensions"})["extensions"]
        if len(extensions) == 1 and extensions[0]["loaded"] == enabled:
            return extensions[0]
        time.sleep(0.1)
    raise RuntimeError(extensions)


def main():
    t = sv.T()
    with tempfile.TemporaryDirectory(prefix="search-extension-memory-") as directory:
        folder = Path(directory)
        patterns = [f"https://site{i}.invalid/*" for i in range(31)] + ["http://localhost/*"]
        (folder / "manifest.json").write_text(json.dumps({
            "manifest_version": 3, "name": "Memory fixture", "version": "1",
            "host_permissions": patterns,
            "content_scripts": [{"matches": patterns, "js": ["content.js"],
                                 "css": ["content.css"], "run_at": "document_start"}],
        }))
        (folder / "content.js").write_text("/*" + "x" * 2_000_000 + "*/\n" + """
globalThis.memoryFixtureRuns = (globalThis.memoryFixtureRuns || 0) + 1;
document.addEventListener('DOMContentLoaded', () => {
    document.documentElement.dataset.memoryFixtureRuns = String(memoryFixtureRuns);
    document.documentElement.dataset.memoryFixtureID = chrome.runtime.id;
});
""")
        (folder / "content.css").write_text("/*" + "x" * 1_000_000 + "*/\nbody { --memory-fixture: yes; }")
        try:
            sv.setup(); sv.launch()
            initial = sv.cmd({"do": "tabs"})["tabs"]
            pages = [sv.page(f"memory-{i}") for i in range(4)]
            for tab in initial:
                sv.sp("close", id=tab["id"])
            time.sleep(2)
            before = footprint()
            sv.cmd({"do": "ext-folder", "path": directory, "yes": True})
            extension = loaded(True)
            time.sleep(3)
            after = footprint()
            print(f"Host footprint: {before:.1f} -> {after:.1f} MiB", flush=True)
            t.ok("many site grants share the script and stylesheet", after - before < 96, after - before)
            t.ok("unmatched pages receive no extension script", all(
                sv.ev(page, "document.documentElement.dataset.memoryFixtureRuns || ''") == "" for page in pages))

            allowed = sv.BASE.replace("127.0.0.1", "localhost") + "/allowed"
            for cycle in range(3):
                if cycle:
                    sv.cmd({"do": "ext-enable", "id": extension["id"], "on": True})
                    loaded(True)
                page = sv.sp("open", url=allowed)["resultID"]
                sv.cmd({"do": "wait", "id": page, "seconds": 10})
                t.ok(f"load {cycle}: script runs once with extension APIs",
                     sv.ev(page, "document.documentElement.dataset.memoryFixtureRuns") == "1"
                     and sv.ev(page, "document.documentElement.dataset.memoryFixtureID") == extension["id"])
                t.ok(f"load {cycle}: script remains isolated from the page",
                     sv.ev(page, "typeof memoryFixtureRuns") == "undefined")
                t.ok(f"load {cycle}: stylesheet applies",
                     sv.ev(page, "getComputedStyle(document.body).getPropertyValue('--memory-fixture').trim()") == "yes")
                sv.sp("close", id=page)
                sv.cmd({"do": "ext-enable", "id": extension["id"], "on": False})
                loaded(False)
                time.sleep(1)
                t.ok(f"unload {cycle}: no accumulating buffers", footprint() - before < 96)
            page = sv.sp("open", url=allowed)["resultID"]
            sv.cmd({"do": "wait", "id": page, "seconds": 10})
            t.ok("disabled extension no longer injects",
                 sv.ev(page, "document.documentElement.dataset.memoryFixtureRuns || ''") == ""
                 and sv.ev(page, "getComputedStyle(document.body).getPropertyValue('--memory-fixture').trim()") == "")
        finally:
            t.done(); sv.finish()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
