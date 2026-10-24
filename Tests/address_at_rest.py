#!/usr/bin/env python3
"""The address at rest on the tab you're on (AtRest.swift), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/address_at_rest.py`. The app
starts hidden in a world of its own (bld-addr-<checkout>, see
split_view.use), is driven through ./bench's socket, and is quit; its world
is removed afterwards. Nothing here makes, shows or brings forward a window:
the column and the strip are pictured off screen (bench column/strip) into
the folder given as the first argument, if any.

What is said is read from the bench's tab list: `atRest`, the line the tab
would show, and `atRestShown`, whether it shows it now. The look-alike and
http pages are only addressed, never needed: what the tab says comes from
the address, loaded or not. Timings: the address field typed into a key at
a time with the setting off and on, interleaved (bench field).
"""
import statistics
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bld-addr")
PORT = sv.BASE.rsplit(":", 1)[1]
SHOTS = sys.argv[1] if len(sys.argv) > 1 else None


def tabs():
    return {t["id"]: t for t in sv.cmd({"do": "tabs"})["tabs"]}


def shown():
    return sorted(id for id, t in tabs().items() if t["atRestShown"])


def ui(**f):
    return sv.cmd({"do": "ui", **f})


def picture(tag):
    if not SHOTS:
        return
    for look in ["light", "dark"]:
        ui(look=look)
        time.sleep(0.4)
        sv.cmd({"do": "column", "path": f"{SHOTS}/{tag}-column-{look}.png", "height": 330})
        sv.cmd({"do": "strip", "path": f"{SHOTS}/{tag}-strip-{look}.png", "width": 1100})
    ui(look="light")


def typing(times=3):
    """Milliseconds from a key into the field to the run loop resting, per key."""
    out = []
    for _ in range(times):
        r = sv.cmd({"do": "field", "text": "github.com/driceroland", "type": True})
        out += [rested for _, rested in r["ms"]]
        sv.cmd({"do": "suggest", "action": "esc"})
        time.sleep(0.3)
    return out


def main():
    t = sv.T()
    try:
        sv.setup(sidebar=True, splitView=True)
        sv.launch()
        first = next(iter(tabs()))
        sv.cmd({"do": "go", "id": first, "url": f"http://localhost:{PORT}/one"})
        time.sleep(1)

        # Off unless turned on.
        key = subprocess.run(["defaults", "read", sv.SUITE, "tabs.address"], capture_output=True, text=True)
        t.ok("off by default: no setting written", key.returncode != 0, key.stdout)
        t.ok("off: no tab says its address", shown() == [], shown())
        t.ok("off: the line is still worked out for the bench", tabs()[first]["atRest"] == f"localhost:{PORT}", tabs()[first])

        # Off, the front tab still warns: plain http and look-alike names.
        warn_http = sv.sp("open", url="http://example.com/off")["resultID"]
        until = time.time() + 10
        while not tabs()[warn_http]["atRest"] and time.time() < until: time.sleep(0.3)
        t.ok("off: plain http is still said on the front tab", shown() == [warn_http]
             and tabs()[warn_http]["atRest"].startswith("Not secure — "), (shown(), tabs()[warn_http]["atRest"]))
        warn_fake = sv.sp("open", url="https://xn--80ak6aa92e.com/off")["resultID"]
        # Said once the page arrives (Tab.restAddress): a real site, so give
        # the network its time.
        until = time.time() + 10
        while not tabs()[warn_fake]["atRest"] and time.time() < until: time.sleep(0.3)
        t.ok("off: a look-alike name is still said, as punycode", shown() == [warn_fake]
             and tabs()[warn_fake]["atRest"] == "xn--80ak6aa92e.com", (shown(), tabs()[warn_fake]["atRest"]))
        plain_https = sv.sp("open", url="https://docs.github.com/off")["resultID"]
        time.sleep(0.6)
        t.ok("off: an ordinary https page keeps its title", shown() == [], shown())
        safe_idn = sv.sp("open", url="https://xn--wgv71a119e.jp/")["resultID"]  # 日本語.jp
        time.sleep(0.6)
        t.ok("off: a name safe in its own alphabet keeps its title", shown() == [], (shown(), tabs()[safe_idn]["atRest"]))
        sv.sp("select", id=first)
        time.sleep(0.4)
        t.ok("off: localhost over http is this Mac, not a warning", shown() == [], shown())

        ui(address=True)
        time.sleep(0.3)
        key = subprocess.run(["defaults", "read", sv.SUITE, "tabs.address"], capture_output=True, text=True).stdout.strip()
        t.ok("the switch is kept", key == "1", key)
        t.ok("on: the front tab says its site", shown() == [first], shown())

        two = sv.sp("open", url=f"http://127.0.0.1:{PORT}/two")["resultID"]
        time.sleep(0.8)
        t.ok("a new front tab: only it says its site", shown() == [two], shown())
        t.ok("by its address", tabs()[two]["atRest"] == f"127.0.0.1:{PORT}", tabs()[two]["atRest"])
        sv.sp("select", id=first)
        time.sleep(0.4)
        t.ok("switching tabs moves it", shown() == [first], shown())

        # A look-alike in Cyrillic letters is shown as the punycode it is.
        fake = sv.sp("open", url="https://xn--80ak6aa92e.com/")["resultID"]
        time.sleep(1)
        said = tabs()[fake]["atRest"]
        t.ok("homograph: shown as punycode", said == "xn--80ak6aa92e.com", said)
        t.ok("homograph: no Cyrillic in what is shown", all(ord(c) < 128 for c in said), said)
        t.ok("homograph: shown on the front tab", shown() == [fake], shown())
        picture("punycode")

        # Plain http, somewhere other than this Mac.
        plain = sv.sp("open", url="http://example.com/")["resultID"]
        time.sleep(1.5)
        said = tabs()[plain]["atRest"]
        t.ok("http: marked Not secure", said.startswith("Not secure — ") and said.endswith("example.com"), said)
        picture("http")

        # A subdomain: all of the host, the site last.
        docs = sv.sp("open", url="https://docs.github.com/en")["resultID"]
        time.sleep(0.5)
        t.ok("subdomain kept before the site", tabs()[docs]["atRest"] == "docs.github.com", tabs()[docs]["atRest"])
        picture("subdomain")

        # Editing the address: the field, not the line.
        ui(edittab="docs.github.com/en")
        time.sleep(0.3)
        t.ok("editing: not said while the field is there", docs not in shown(), shown())
        ui(finishedit=True)
        time.sleep(0.4)
        t.ok("after editing: said again", shown() == [docs], shown())

        # Split View: the half you're on says its site, the other doesn't.
        sv.sp("pair", **{"id": two, "with": first, "side": "right"})
        time.sleep(0.8)
        sv.sp("focus", id=two)
        time.sleep(0.5)
        t.ok("split: the focused half says it", shown() == [two], shown())
        picture("split")
        sv.sp("focus", id=first)
        time.sleep(0.5)
        t.ok("split: focus moves it", shown() == [first], shown())

        # A private tab says it too; nothing about it is kept.
        before = sorted(tabs())
        sv.sp("private")
        time.sleep(0.6)
        shy = next(id for id in tabs() if id not in before)
        t.ok("private: a private tab", tabs()[shy]["shy"], tabs()[shy])
        t.ok("private: blank says nothing", shown() == [], shown())
        sv.cmd({"do": "go", "id": shy, "url": f"http://localhost:{PORT}/secret"})
        time.sleep(1)
        t.ok("private: its site", shown() == [shy] and tabs()[shy]["atRest"] == f"localhost:{PORT}", (shown(), tabs()[shy]))
        picture("private")

        # Typing in the field, a key at a time: no slower with it on.
        sv.sp("select", id=docs)
        time.sleep(0.4)
        on, off = [], []
        for _ in range(3):
            ui(address=False); time.sleep(0.3); off += typing(1)
            ui(address=True); time.sleep(0.3); on += typing(1)
        mo, mf = statistics.median(on), statistics.median(off)
        print(f"  typing, ms per key to rest: on median {mo:.2f} p90 {sorted(on)[int(len(on)*0.9)]:.2f}"
              f" | off median {mf:.2f} p90 {sorted(off)[int(len(off)*0.9)]:.2f} ({len(on)} keys each)")
        t.ok("typing: no slower with it on (within 1 ms or 25%)", mo <= max(mf * 1.25, mf + 1), (mo, mf))

        ui(address=False)
        time.sleep(0.3)
        t.ok("off again: nothing said", shown() == [], shown())
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
