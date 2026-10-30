#!/usr/bin/env python3
"""⌘T's floating field over the page, as Arc's ⌘T, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/floating_new_tab.py`. With
Settings › Spaces & Pins › New tab in a floating field on, ⌘T raises the
field over the page and ⌘T again puts it away; a held ⌘T leaves it up. No
tab is made by any of it. The list shows only the open tabs the words
clearly name, each once, and Return goes to the most recent of them: what
starts a name or an address, from one letter, or a word inside a name,
from two. An address typed out lists only the tabs whose address it starts;
any other opens as typed. ⌘T is pressed through the app, so the window's key monitor sees
it as it sees a hand's; no window is made or shown.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("floating-new-tab")

CMD_T, H = 17, 4


def press(code, chars, mods=()):
    return sv.cmd({"do": "press", "code": code, "chars": chars, "mods": list(mods)})


def cmd_t(*mods):
    press(CMD_T, "t", ["cmd", *mods])
    time.sleep(0.3)


def state():
    return {"up": sv.cmd({"do": "probe"})["field"], "tabs": len(sv.sp("state")["tabs"])}


def type_in(text):
    """Letters into the field that is up, a key at a time; the list after."""
    sv.cmd({"do": "field", "text": text, "type": True})
    time.sleep(0.3)
    return sv.cmd({"do": "suggest"})


def front():
    st = sv.sp("state")
    return next((x for x in st["tabs"] if x["id"] == st.get("activeID")), None)


def rows_for(offers, name):
    return [o for o in offers if o[2].endswith("/" + name)]


def offered(s, name, at=0):
    """The open tab at that row of the list, and the one Return takes."""
    o = s["offers"][at] if len(s["offers"]) > at else None
    return o is not None and o[1] == "open" and o[2].endswith("/" + name)


def unlisted(s, name):
    return all(o[1] != "open" for o in rows_for(s["offers"], name))


def launch_with(a, text):
    """⌘T's field over page a with text typed in it: the list, then Escape."""
    sv.sp("select", id=a); time.sleep(0.3)
    cmd_t()
    s = type_in(text)
    sv.cmd({"do": "suggest", "action": "esc"}); time.sleep(0.2)
    return s


def toggle(t):
    tabs = state()["tabs"]

    cmd_t()
    s = state()
    t.ok("⌘T raises the field over the page, with no new tab", s["up"] and s["tabs"] == tabs, s)

    cmd_t()
    s = state()
    t.ok("⌘T again puts it away, with no new tab", not s["up"] and s["tabs"] == tabs, s)

    cmd_t(); cmd_t("repeat")
    s = state()
    t.ok("⌘T held leaves the field up", s["up"] and s["tabs"] == tabs, s)
    cmd_t()
    t.ok("then ⌘T puts it away", not state()["up"])

    cmd_t(); press(H, "h"); time.sleep(0.2); cmd_t()
    s = state()
    t.ok("⌘T with something typed puts it away", not s["up"] and s["tabs"] == tabs, s)


def open_tabs(t, a, kettle):
    # The probe's own tabs leave no history, so kettle is visited once in a
    # tab of the field's, which takes the bench's place; it is closed first,
    # or its address would go to it. History matches the host, never the
    # path, so its row is asked for by the host.
    sv.sp("close", id=kettle)
    sv.sp("select", id=a); time.sleep(0.3)
    cmd_t(); type_in(f"{sv.BASE}/kettle"); sv.cmd({"do": "suggest", "action": "go"}); time.sleep(1)
    kettle = front()["id"]
    sv.sp("select", id=a); time.sleep(0.3)
    tabs = state()["tabs"]

    sv.cmd({"do": "field", "text": "127.0", "type": True}); time.sleep(0.3)
    s = sv.cmd({"do": "suggest"})
    t.ok("⌘L's field lists the page from history", [o[1] for o in rows_for(s["offers"], "kettle")] == ["visited"], s["offers"])
    t.ok("and leaves open tabs to ⌘K", all(o[1] != "open" for o in s["offers"]), s["offers"])
    sv.cmd({"do": "suggest", "action": "esc"}); time.sleep(0.2)

    s = launch_with(a, "127.0")
    t.ok("⌘T's field lists it once, as the open tab, not again from history", [o[1] for o in rows_for(s["offers"], "kettle")] == ["open"], s["offers"])

    sv.sp("select", id=a); time.sleep(0.3)
    cmd_t()
    s = type_in("kett")
    t.ok("an open tab named by the words comes first", offered(s, "kettle"), s["offers"])
    t.ok("and is what Return takes", s["picked"] == 0, s)
    s = sv.cmd({"do": "suggest", "action": "go"})
    f = front()
    t.ok("Return goes to that tab, with no new one", f and f["id"] == kettle and state()["tabs"] == tabs, (f, state()))
    t.ok("and the field is down", not state()["up"])

    s = launch_with(a, "ttle")
    t.ok("letters from inside a word: the tab isn't listed", unlisted(s, "kettle") and s["picked"] == -1, s)

    s = launch_with(a, "k")
    t.ok("one letter that starts a tab's name goes to it", s["picked"] == 0 and offered(s, "kettle"), s)

    s = launch_with(a, "a")
    t.ok("one letter that starts only a word inside a name: not listed", unlisted(s, "parser") and s["picked"] == -1, s)

    s = launch_with(a, "wr")
    t.ok("two letters that start a word inside its name go to it", s["picked"] == 0 and offered(s, "parser"), s)

    s = launch_with(a, "localh")
    t.ok("the start of its address goes to it", s["picked"] == 0 and offered(s, "parser"), s)
    t.ok("and nothing grey in the field finishes it as somewhere else", s["ending"] == "", s)

    port = sv.srv.server_port
    s = launch_with(a, f"localhost:{port}/pa")
    t.ok("the start of its address typed out, port and all, goes to it", s["picked"] == 0 and offered(s, "parser"), s)

    sv.sp("select", id=a); time.sleep(0.3)
    cmd_t()
    s = type_in(f"http://localhost:{port}/pa")
    t.ok("and with http:// in front", s["picked"] == 0 and offered(s, "parser"), s)
    sv.cmd({"do": "suggest", "action": "go"}); time.sleep(0.5)
    f = front()
    t.ok("Return switches to it, with no new tab", f and f["url"].endswith("/parser") and state()["tabs"] == tabs, (f, state()))

    # No port is port 80, another server than the parser's, though the
    # address the tab shows leaves its port off.
    sv.sp("select", id=a); time.sleep(0.3)
    cmd_t()
    s = type_in("localhost/pa")
    t.ok("an address no open tab is at: no tab listed", unlisted(s, "parser") and s["picked"] == -1, s)
    n = state()["tabs"]
    sv.cmd({"do": "suggest", "action": "go"}); time.sleep(0.5)
    f = front()
    t.ok("Return opens it as typed, in a new tab", f and "localhost/pa" in f["url"] and state()["tabs"] == n + 1, (f, state()))

    # Settings › Spaces & Pins › Address bar commands is on (see main), so
    # the word alone is History's command.
    s = launch_with(a, "history")
    t.ok("a command's word: the command on top, the tab it names under it", s["offers"][0][1] == "command" and offered(s, "history", 1), s["offers"])
    t.ok("and the tab isn't picked over the command", s["picked"] == -1, s)

    # github, left last, only has an h in it; hacker, left before it, starts
    # with one.
    sv.page("hacker"); sv.page("github")
    s = launch_with(a, "h")
    t.ok("one letter: the newest tab it starts goes first, past a newer one it only brushes", s["picked"] == 0 and offered(s, "hacker") and unlisted(s, "github"), s)

    # *.localhost is this Mac, as localhost is.
    sv.sp("open", url=f"http://www.localhost:{port}/kiln"); time.sleep(0.7)
    s = launch_with(a, f"localhost:{port}/ki")
    t.ok("its address typed without the www. it has goes to it", s["picked"] == 0 and offered(s, "kiln"), s)


def main():
    t = sv.T()
    try:
        sv.setup(**{"newtab.floating": True, "commandbar": True}); sv.launch()
        kettle = sv.page("kettle")
        sv.page("history")
        parser = sv.sp("open", url=f"http://localhost:{sv.srv.server_port}/parser")["resultID"]; time.sleep(0.7)
        sv.ev(parser, "document.title = 'How to write a parser'; 1"); time.sleep(0.3)
        a = sv.page("a")
        sv.sp("select", id=a); time.sleep(0.3)
        toggle(t)
        open_tabs(t, a, kettle)
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
