"""New tab placement through the real browser in a hidden, isolated probe.

Build first (`./build.sh debug`), then `python3 Tests/new_tab_end.py`.
"""
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("new-tab-end")


def order(state=None):
    return [x["id"] for x in (state or sv.sp("state"))["tabs"]]


def loose(state, pins):
    return [tab for tab, group in zip(state["tabs"], state["groupIDs"])
            if not group and tab["id"] not in pins]


def run(t, place, sidebar=True):
    sv.setup(sidebar=sidebar, **{"tabs.groups": True, "splitView": True})
    if place != "next":
        subprocess.run(["defaults", "write", sv.SUITE, "tabs.newPlace", place], check=True)
    sv.launch()
    try:
        a = sv.page("a")
        b = sv.page("b")
        c = sv.page("c")
        sv.sp("select", id=a)
        d = sv.page("d")
        now = order()
        target = {"next": now.index(a) + 1, "top": 0, "end": len(now) - 1}[place]
        t.ok(f"{place}: opened page has the chosen position", now[target] == d, now)

        # The initial blank is reused, then navigated so the next one is fresh.
        blank = sv.sp("newTab")["activeID"]
        now = order()
        target = {"next": now.index(d) + 1, "top": 0, "end": len(now) - 1}[place]
        t.ok(f"{place}: reused blank has the chosen position", now[target] == blank, now)
        t.ok(f"{place}: repeated new tab reuses the same blank", sv.sp("newTab")["activeID"] == blank)
        sv.cmd({"do": "go", "id": blank, "url": f"{sv.BASE}/filled"})
        time.sleep(0.7)
        fresh = sv.sp("newTab")["activeID"]
        now = order()
        target = {"next": now.index(blank) + 1, "top": 0, "end": len(now) - 1}[place]
        t.ok(f"{place}: fresh blank has the chosen position", fresh != blank and now[target] == fresh, now)

        if place != "top":
            # Reuse from either side of the current tab, not only the initial slot.
            for anchor in [a, c]:
                sv.sp("select", id=anchor)
                reused = sv.sp("newTab")["activeID"]
                now = order()
                target = now.index(anchor) + 1 if place == "next" else len(now) - 1
                t.ok(f"{place}: reused blank follows the current choice", reused == fresh and now[target] == fresh, now)
            sv.sp("select", id=a)
            private = sv.sp("private")["activeID"]
            now = order()
            target = now.index(a) + 1 if place == "next" else len(now) - 1
            t.ok(f"{place}: fresh private tab follows the current choice", now[target] == private, now)
            sv.sp("select", id=c)
            reused = sv.sp("private")["activeID"]
            now = order()
            target = now.index(c) + 1 if place == "next" else len(now) - 1
            t.ok(f"{place}: reused private tab follows the current choice", reused == private and now[target] == private, now)
            if place == "next":
                sv.sp("pair", id=b, **{"with": a, "side": "right"})
                for slot in [0, len(order()) - 1]:
                    sv.sp("move", id=fresh, to=slot)
                    sv.sp("select", id=a)
                    reused = sv.sp("newTab")["activeID"]
                    now = order()
                    t.ok("next: reused blank goes after the whole split", reused == fresh and now.index(fresh) == now.index(b) + 1, now)
            sv.sp("select", id=d)
            sv.ev(d, "document.body.innerHTML = `<button id='go' onclick=\"window.open('/popup')\">Open</button>`")
            sv.cmd({"do": "tap", "id": d, "selector": "#go"})
            time.sleep(1)
            state = sv.sp("state")
            popup = next(tab["id"] for tab in state["tabs"] if tab["url"] == f"{sv.BASE}/popup")
            now = order(state)
            target = now.index(d) + 1 if place == "next" else len(now) - 1
            t.ok(f"{place}: foreground popup has the chosen position", now[target] == popup, now)
            return

        sv.cmd({"do": "pin", "id": a})
        sv.cmd({"do": "pin", "id": b, "listed": True})
        sv.sp("select", id=a)
        e = sv.page("after-pins")
        t.ok("top: square and row pins stay before a new page", order()[:3] == [a, b, e], order())
        sv.sp("newTab")
        t.ok("top: reused blank stays after pins", order()[:3] == [a, b, fresh], order())

        # Explicit ordering is used by batches and extension API openings.
        first = sv.sp("open", url=f"{sv.BASE}/batch-1", atEnd=True)["resultID"]
        second = sv.sp("open", url=f"{sv.BASE}/batch-2", atEnd=True)["resultID"]
        t.ok("top: explicitly ordered openings still append", order()[-2:] == [first, second], order())
        sv.sp("select", id=c)
        background = sv.sp("open", url=f"{sv.BASE}/behind", foreground=False)["resultID"]
        t.ok("top: background link is first without taking focus", order()[2] == background and sv.sp("state")["activeID"] == c)

        state = sv.sp("group", id=c)
        group = state["groups"][0]["id"]
        grouped = sv.sp("open", url=f"{sv.BASE}/grouped", **{"from": c})["resultID"]
        state = sv.sp("state")
        members = [tab["id"] for tab, gid in zip(state["tabs"], state["groupIDs"]) if gid == group]
        t.ok("top: a grouped link is first in its original group", members == [grouped, c], members)

        sv.cmd({"do": "peek", "url": f"{sv.BASE}/kept-peek"})
        sv.cmd({"do": "ui", "peeklink": "keep"})
        state = sv.sp("state")
        kept = next(tab for tab, gid in zip(state["tabs"], state["groupIDs"]) if gid == group)
        t.ok("top: a kept peek is first in its original group", kept["url"] == f"{sv.BASE}/kept-peek")

        sv.sp("pair", id=second, **{"with": first, "side": "right"})
        paired = sv.sp("state")["splits"]
        sv.page("after-pair")
        now = order()
        t.ok("top: opening a page preserves the existing split", sv.sp("state")["splits"] == paired and now.index(second) == now.index(first) + 1)

        private = sv.sp("private")["activeID"]
        state = sv.sp("state")
        t.ok("top: new private blank is first below pins and groups",
             loose(state, [a, b])[0]["id"] == private and loose(state, [a, b])[0]["shy"])
        sv.sp("move", id=private, to=len(order()) - 1)
        sv.sp("select", id=c)
        state = sv.sp("private")
        t.ok("top: private blank is reused and moved back", state["activeID"] == private and loose(state, [a, b])[0]["id"] == private)
        t.ok("top: Cmd-T on private blank stays private", sv.sp("newTab")["activeID"] == private)

        # A blank split half must stay in its pair when a private tab is requested.
        sv.cmd({"do": "go", "id": private, "url": f"{sv.BASE}/private"})
        time.sleep(0.7)
        state = sv.sp("start")
        private_pair = state["splits"][-1]
        state = sv.sp("private")
        t.ok("top: new private tab leaves a blank split half in its pair",
             private_pair in state["splits"] and state["activeID"] not in private_pair["tabs"])

        # Trusted native input exercises WebKit's foreground window.open path.
        sv.sp("select", id=d)
        sv.ev(d, "document.body.innerHTML = `<button id='go' onclick=\"window.open('/popup')\">Open</button>`")
        sv.cmd({"do": "tap", "id": d, "selector": "#go"})
        time.sleep(1)
        state = sv.sp("state")
        t.ok("top: foreground popup is first below pins and groups",
             loose(state, [a, b])[0]["url"] == f"{sv.BASE}/popup"
             and loose(state, [a, b])[0]["id"] == state["activeID"], loose(state, [a, b])[0])
    finally:
        sv.finish()


def main():
    t = sv.T()
    try:
        for sidebar in (True, False):
            for place in ("next", "end", "top"):
                run(t, place, sidebar=sidebar)
    finally:
        t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
