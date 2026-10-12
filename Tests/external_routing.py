"""External domain routing, in an isolated hidden probe.

Build first (`./build.sh debug`), then `python3 Tests/external_routing.py`.
Uses the existing windows/link bench command; no real browser state is changed.
"""
import json
import subprocess
import uuid
from pathlib import Path

import split_view as sv

sv.use("external-routing")


def seed(enabled=True, destination=True, spaces=True):
    sv.setup(**{"spaces": spaces})
    work = str(uuid.uuid4()).upper()
    folder = Path(sv.SUPPORT)
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "spaces.json").write_text(json.dumps([
        {"id": sv.FIRST_SPACE, "name": "Personal", "colour": 0},
        {"id": work, "name": "Work", "colour": 1},
    ]))
    rule = {"id": str(uuid.uuid4()), "domain": "example.com",
            "spaceID": work if destination else str(uuid.uuid4()), "spaceName": "Work", "enabled": True}
    data = json.dumps({"enabled": enabled, "rules": [rule]}).encode()
    subprocess.run(["defaults", "write", sv.SUITE, "external.routing", "-data", data.hex()], check=True)
    subprocess.run(["defaults", "write", sv.SUITE, "space.current", sv.FIRST_SPACE], check=True)
    sv.launch()


def link():
    return sv.cmd({"do": "windows", "action": "link", "url": "https://example.com/routed"})["windows"][0]


def main():
    t = sv.T()
    try:
        seed()
        state = link()
        t.ok("external link switches before opening", state["space"] == "Work" and "https://example.com/routed" in state["tabs"], state)
        # Internal opening never invokes the external policy.
        sv.cmd({"do": "space", "action": "go", "index": 1})
        sv.cmd({"do": "open", "url": "https://example.com/internal"})
        state = sv.cmd({"do": "space"})
        t.ok("internal opening stays in its current space", state["current"] == "Personal", state)
        sv.quit()
        seed(destination=False)
        state = link()
        t.ok("deleted destination blocks matching link", state["space"] == "Personal" and "https://example.com/routed" not in state["tabs"], state)
        sv.quit()
        seed(spaces=False)
        state = link()
        t.ok("Spaces off blocks enabled routing", "https://example.com/routed" not in state["tabs"], state)
        sv.quit()
        seed(enabled=False, destination=False)
        state = link()
        t.ok("routing off keeps normal external behavior", state["space"] == "Personal" and "https://example.com/routed" in state["tabs"], state)
    finally:
        sv.finish()
    t.done()
    raise SystemExit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
