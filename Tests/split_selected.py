#!/usr/bin/env python3
"""Two tabs picked in the column (⌘-click), then Open 2 Tabs in Split View
or ⌥⌘N: those two side by side. In a hidden probe.

Build first (`./build.sh`), then `python3 Tests/split_selected.py`. It uses
the split suite's harness: started hidden, no window made or shown,
everything removed afterwards. `split pick` makes the ⌘-clicks the column
makes (Browser.extendTabSelection), `split pairPicked` is the menu item's
action and `split start` is ⌥⌘N's. That the menu shows the item, reads
"Open 2 Tabs in Split View" and is off with three picked is looked at by
hand on a release candidate.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# A world of its own (see use()).
sv.use("bld-sp2")

t = sv.T()
def state(): return sv.sp("state")
def web(st, id): return next(x["web"] for x in st["tabs"] if x["id"] == id)
def mark(id, value): sv.ev(id, f"window.__sp2 = '{value}'; document.title")
def marked(id): return sv.ev(id, "window.__sp2 || 'gone'")
def pick(*ids): return sv.sp("pick", ids=list(ids))
def pairs(st): return [p["tabs"] for p in st["splits"]]
def blanks(st): return [x["id"] for x in st["tabs"] if x["blank"]]


def case_two(t):
    """two picked: paired, in the column's order, pages kept"""
    sv.setup(splitView=True, sidebar=True, **{"tabs.groups": False}); sv.launch()
    a = sv.page("a"); b = sv.page("b"); c = sv.page("c"); d = sv.page("d")
    sv.sp("select", id=d)
    st = state()
    before = {i: web(st, i) for i in (a, c)}
    empty = blanks(st); at = sv.order(st).index(a)
    mark(a, "kept-a"); mark(c, "kept-c")
    # c first, then a: the column's order decides, not the order of the clicks.
    st = pick(c, a)
    t.ok("pick: exactly the two", sorted(st["selected"]) == sorted([a, c]), st["selected"])
    t.ok("pick: the pair on offer is [a, c]", st["pickedPair"] == [a, c], st["pickedPair"])
    st = sv.sp("pairPicked", id=c)
    t.ok("paired: [a, c], a on the left", pairs(st) == [[a, c]], pairs(st))
    o = sv.order(st)
    t.ok("paired: c beside a, where a was", o.index(c) == o.index(a) + 1 and o.index(a) == at, o)
    t.ok("paired: no empty page made", blanks(st) == empty, blanks(st))
    t.ok("paired: the tab right-clicked has the keys", st["activeID"] == c, st["activeID"])
    t.ok("paired: both on screen", sorted(st["visibleIDs"]) == sorted([a, c]), st["visibleIDs"])
    t.ok("paired: the selection is cleared", st["selected"] == [], st["selected"])
    t.ok("paired: the same web views", all(web(st, i) == before[i] and before[i] != "" for i in (a, c)), (before, {i: web(st, i) for i in (a, c)}))
    time.sleep(0.5)
    t.ok("paired: neither page loaded again", marked(a) == "kept-a" and marked(c) == "kept-c", (marked(a), marked(c)))

    # ⌥⌘N with two picked: the same, here b and d. Right-clicked on nothing,
    # so the right one has the keys, as a drag gives them to the one dropped.
    sv.sp("select", id=b)
    mark(d, "kept-d"); wd = web(state(), d)
    st = pick(b, d)
    st = sv.sp("start")
    t.ok("⌥⌘N: [b, d] paired, the other pair kept", sorted(pairs(st)) == sorted([[a, c], [b, d]]), pairs(st))
    t.ok("⌥⌘N: no empty page made", blanks(st) == empty, blanks(st))
    t.ok("⌥⌘N: the selection is cleared", st["selected"] == [], st["selected"])
    t.ok("⌥⌘N: d's page kept", web(st, d) == wd and marked(d) == "kept-d", (wd, web(st, d)))

    # Both pages of one pair picked: nothing to pair (the menu shows the pair's own items).
    st = pick(a, c)
    t.ok("one pair's two pages: no pair on offer", st["pickedPair"] == [] and st["pickedPaired"] is True, (st["pickedPair"], st["pickedPaired"]))
    st = sv.sp("pairPicked", id=a)
    t.ok("one pair's two pages: pairs unchanged", sorted(pairs(st)) == sorted([[a, c], [b, d]]), pairs(st))

    # One from each pair: each leaves its pair first, as a drag does.
    st = pick(c, b)
    t.ok("one from each pair: [b, c] on offer", st["pickedPair"] in ([b, c], [c, b]), st["pickedPair"])
    left, right = st["pickedPair"]
    st = sv.sp("pairPicked", id=b)
    t.ok("one from each pair: one pair, the two picked", pairs(st) == [[left, right]], pairs(st))
    t.ok("one from each pair: a and d alone", not any(a in p or d in p for p in pairs(st)), pairs(st))
    t.ok("one from each pair: no empty page made", blanks(st) == empty, blanks(st))


def case_one_and_three(t):
    """one picked: as before; three picked: off, ⌥⌘N as before"""
    sv.setup(splitView=True, sidebar=True, **{"tabs.groups": False}); sv.launch()
    a = sv.page("a"); b = sv.page("b"); c = sv.page("c")
    sv.sp("select", id=a)
    st = pick(b)
    t.ok("one picked: just b", st["selected"] == [b] and st["pickedPair"] == [], (st["selected"], st["pickedPair"]))
    st = sv.sp("openIn", id=b)
    t.ok("one picked: Open in Split View puts b beside the page on screen", pairs(st) == [[a, b]], pairs(st))
    # ⌥⌘N on c, alone on screen, with only b picked.
    sv.sp("select", id=c)
    empty = blanks(state())
    st = pick(b)
    st = sv.sp("start")
    new = [x for x in blanks(st) if x not in empty]
    t.ok("one picked: ⌥⌘N splits the page in front with an empty one", len(new) == 1 and [c, new[0]] in pairs(st), (pairs(st), new))

    sv.setup(splitView=True, sidebar=True, **{"tabs.groups": False}); sv.launch()
    a = sv.page("a"); b = sv.page("b"); c = sv.page("c"); d = sv.page("d")
    sv.sp("select", id=d)
    empty = blanks(state())
    st = pick(a, b, c)
    t.ok("three picked: all three", sorted(st["selected"]) == sorted([a, b, c]), st["selected"])
    t.ok("three picked: no pair on offer (the item is off)", st["pickedPair"] == [], st["pickedPair"])
    st = sv.sp("pairPicked", id=a)
    t.ok("three picked: the menu's action does nothing", pairs(st) == [] and sorted(st["selected"]) == sorted([a, b, c]), (pairs(st), st["selected"]))
    st = sv.sp("start")
    new = [x for x in blanks(st) if x not in empty]
    t.ok("three picked: ⌥⌘N splits the page in front, as before", len(new) == 1 and pairs(st) == [[d, new[0]]], (pairs(st), new))


def case_pins_private_off(t):
    """a pin, a private tab, the switch off"""
    sv.setup(splitView=True, sidebar=True, **{"tabs.groups": False}); sv.launch()
    p = sv.page("p"); a = sv.page("a"); b = sv.page("b")
    sv.cmd({"do": "pin", "id": p})
    sv.sp("select", id=b)
    st = pick(p, a)
    t.ok("pin and a tab: pair on offer", st["pickedPair"] == [p, a], st["pickedPair"])
    st = sv.sp("pairPicked", id=a)
    t.ok("pin and a tab: the pin stays out of the pair", not any(p in x for x in pairs(st)), pairs(st))
    copy = [x["id"] for x in st["tabs"] if x["url"].endswith("/p") and x["id"] != p]
    t.ok("pin and a tab: its page goes in on the left, beside a", copy and pairs(st) == [[copy[0], a]], (pairs(st), copy))
    o = sv.order(st)
    t.ok("pin and a tab: the pair is where a was", copy and o.index(copy[0]) + 1 == o.index(a) and o.index(b) == o.index(a) + 1, o)
    t.ok("pin and a tab: a has the keys, the selection cleared", st["activeID"] == a and st["selected"] == [], (st["activeID"], st["selected"]))

    # A private tab and an ordinary one never share a pair.
    st = sv.sp("private"); shy = next(x["id"] for x in st["tabs"] if x["shy"])
    st = pick(b, shy)
    t.ok("private and not: no pair on offer", st["pickedPair"] == [], (st["selected"], st["pickedPair"]))

    # The switch off: nothing on offer, ⌥⌘N does nothing.
    sv.sp("enabled", on=False)
    st = pick(a, b)
    t.ok("switch off: no pair on offer", st["pickedPair"] == [], st["pickedPair"])


def main():
    for case in [case_two, case_one_and_three, case_pins_private_off]:
        print(f"— {case.__doc__}")
        try:
            case(t)
        except Exception as error:
            t.ok(f"{case.__name__} ran to the end", False, error)
        finally:
            sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
