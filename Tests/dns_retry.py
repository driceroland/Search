#!/usr/bin/env python3
"""A site that couldn't be found for a moment loads by itself (idea 1284).

Build first (`./build.sh debug`), then `python3 Tests/dns_retry.py`. A hidden
probe in a world of its own; Bench `dnsfail` makes the next loads of a host
fail as WebKit fails a lookup (NSURLErrorCannotFindHost), before anything is
asked of the network. Checked: the page says it is trying again and arrives
by itself after the tries (1 s, then 3 s); a tab out of sight waits until it
is selected; a network change tries at once; a POST and an address typed
with no scheme to a site never visited are not tried again and say
"Couldn't find this site." with the hint. No window is shown or brought
forward, and nothing plays sound.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("dns-retry")

TRYING = "Couldn't find this site. Trying again…"
GAVE_UP = "Couldn't find this site.\nCheck the address or your connection."
HOST = "127.0.0.1"
PORT = sv.srv.server_port


def tab(id):
    return next(t for t in sv.cmd({"do": "tabs"})["tabs"] if t["id"] == id)


def until(id, check, seconds):
    end = time.time() + seconds
    while time.time() < end:
        t = tab(id)
        if check(t):
            return t
        time.sleep(0.1)
    return tab(id)


def front_tab(url):
    """A tab in the window, in front, on `url`."""
    id = sv.cmd({"do": "open", "url": "about:blank", "room": False})["id"]
    sv.cmd({"do": "select", "id": id})
    time.sleep(0.5)
    return id


if __name__ == "__main__":
    t = sv.T()
    try:
        sv.setup()
        sv.launch()
        time.sleep(1.0)

        # 1. In sight: two failed lookups, then the site is there.
        id = front_tab("about:blank")
        sv.cmd({"do": "dnsfail", "host": HOST, "times": 2})
        start = time.time()
        sv.cmd({"do": "go", "id": id, "url": f"{sv.BASE}/hello"})
        first = until(id, lambda x: x["failure"] != "", 3)
        t.ok("says it is trying again", first["failure"] == TRYING, first)
        after1 = until(id, lambda x: x["dnsTries"] >= 1, 3)
        t.ok("first try about a second later", after1["dnsTries"] >= 1 and 0.8 < time.time() - start < 2.5, (after1, time.time() - start))
        loaded = until(id, lambda x: x["failure"] == "" and x["title"] == "hello", 8)
        took = time.time() - start
        t.ok("the page arrived by itself", loaded["failure"] == "" and loaded["title"] == "hello", loaded)
        t.ok("after the second try (1 s + 3 s)", loaded["dnsTries"] == 2 and 3.5 < took < 7, (loaded["dnsTries"], took))
        t.ok("nothing left pending", loaded["dnsPending"] is False, loaded)

        # 2. Out of sight: no try until the tab is looked at.
        sv.cmd({"do": "dnsfail", "host": HOST, "times": 1})
        bg = sv.cmd({"do": "open", "url": f"{sv.BASE}/behind"})["id"]
        waiting = until(bg, lambda x: x["failure"] != "", 3)
        time.sleep(2.5)
        waiting = tab(bg)
        t.ok("background tab waits, untried", waiting["failure"] == TRYING and waiting["dnsTries"] == 0 and waiting["dnsPending"], waiting)
        sv.cmd({"do": "select", "id": bg})
        shown = until(bg, lambda x: x["title"] == "behind", 4)
        t.ok("loads once selected", shown["title"] == "behind" and shown["failure"] == "" and shown["dnsTries"] == 1, shown)

        # 3. A network change tries at once, not a second later.
        id = front_tab("about:blank")
        sv.cmd({"do": "dnsfail", "host": HOST, "times": 1})
        sv.cmd({"do": "go", "id": id, "url": f"{sv.BASE}/network"})
        until(id, lambda x: x["failure"] != "", 3)
        start = time.time()
        sv.cmd({"do": "dnsfail", "network": True})
        net = until(id, lambda x: x["title"] == "network", 3)
        t.ok("network change: loaded at once", net["title"] == "network" and time.time() - start < 0.8, (net, time.time() - start))

        # 4. A POST is never sent again.
        id = front_tab("about:blank")
        sv.cmd({"do": "go", "id": id, "url": f"http://localhost:{PORT}/formpage"})
        time.sleep(1.0)
        sv.cmd({"do": "eval", "id": id, "js": f"document.body.innerHTML = \"<form method=post action='http://{HOST}:{PORT}/posted'><input name=a value=1></form>\"; 1"})
        sv.cmd({"do": "dnsfail", "host": HOST, "times": 5})
        sv.cmd({"do": "eval", "id": id, "js": "document.forms[0].submit(); 1"})
        posted = until(id, lambda x: x["failure"] != "", 3)
        time.sleep(2.5)
        posted = tab(id)
        left = sv.cmd({"do": "dnsfail"})["left"].get(HOST)
        t.ok("POST: gave up at once, with the hint", posted["failure"] == GAVE_UP and posted["dnsTries"] == 0 and not posted["dnsPending"], posted)
        t.ok("POST: asked for once only", left == 4, left)

        # 5. A typed guess at a site never visited: a typo, not tried again.
        id = front_tab("about:blank")
        sv.cmd({"do": "dnsfail", "host": "dnstypo.example", "times": 3})
        sv.cmd({"do": "field", "text": "dnstypo.example/x", "go": True})
        typo = until(id, lambda x: x["failure"] != "", 3)
        time.sleep(2.0)
        typo = tab(id)
        left = sv.cmd({"do": "dnsfail"})["left"].get("dnstypo.example")
        t.ok("typo: says it couldn't find it, with the hint", typo["failure"] == GAVE_UP and not typo["dnsPending"], typo)
        t.ok("typo: asked for once only", left == 2, left)
    finally:
        sv.finish()
        t.done()
    sys.exit(1 if t.failed else 0)
