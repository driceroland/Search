#!/usr/bin/env python3
"""A page on the home network by its Bonjour name loads (umbrel.local, X 27 Nov).

Build first (`./build.sh debug`), then `python3 Tests/local_names.py`. A hidden
probe in a world of its own. A real .local name is made for the run: dns-sd
registers a proxy record that mDNSResponder answers with 127.0.0.1, so the
name is looked up the way umbrel.local is (multicast DNS, not the hosts file),
and a plain-http server on 127.0.0.1 stands behind it, with no HTTPS at all.
Checked with Try HTTPS first on (its default), the way a user has it: an
http:// address, an address typed with no scheme, in capitals, and a link.
No window is shown or brought forward, and nothing plays sound.
"""
import random
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("local-names")
PORT = sv.srv.server_port
NAME = f"ocprobe{random.randrange(10**6)}.local"


def tab(id):
    return next(t for t in sv.cmd({"do": "tabs"})["tabs"] if t["id"] == id)


def until(id, check, seconds):
    end = time.time() + seconds
    while time.time() < end:
        t = tab(id)
        if check(t):
            return t
        time.sleep(0.2)
    return tab(id)


def blank():
    id = sv.cmd({"do": "open", "url": "about:blank", "room": False})["id"]
    sv.cmd({"do": "select", "id": id})
    time.sleep(0.5)
    return id


if __name__ == "__main__":
    t = sv.T()
    mdns = subprocess.Popen(["dns-sd", "-P", NAME.split(".")[0], "_http._tcp", "local", str(PORT), NAME, "127.0.0.1"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(2)
        sv.setup()
        sv.launch()
        time.sleep(1.0)

        def loads(label, send, title, seconds=12):
            id = blank()
            send(id)
            got = until(id, lambda x: x["title"] == title, seconds)
            t.ok(label, got["title"] == title and got["failure"] == "", got)

        loads("http://name:port/ by address", lambda id: sv.cmd({"do": "go", "id": id, "url": f"http://{NAME}:{PORT}/one"}), "one")
        loads("typed with no scheme", lambda id: sv.cmd({"do": "field", "text": f"{NAME}:{PORT}/two", "go": True}), "two")
        loads("typed in capitals", lambda id: sv.cmd({"do": "field", "text": f"{NAME.capitalize()}:{PORT}/three", "go": True}), "three")
        loads("http://Name (capitals) by address", lambda id: sv.cmd({"do": "go", "id": id, "url": f"http://{NAME.capitalize()}:{PORT}/four"}), "four")
    finally:
        mdns.terminate()
        sv.finish()
        t.done()
    sys.exit(1 if t.failed else 0)
