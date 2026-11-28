#!/usr/bin/env python3
"""Settings › Spaces & Pins › Advanced › Use the same tab across spaces, in a
hidden probe: which space holds a shared pin's page, what each space keeps in
front, what stays apart (separate sign-ins, other windows, other profiles),
and how a space is drawn on its way in.

Build first (`./build.sh debug`), then `python3 Tests/pin_same_tab.py`. It
uses the split suite's harness in a world of its own (see split_view.use()),
so it can run beside that suite.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("pin-same-tab")
KEY = "pins.sameTab"


def command(operation, **fields):
    return sv.cmd({"do": operation, **fields})


def settled(window=1, done=lambda state: True, within=5):
    """The window's state once `done` says so and two looks in a row agree:
    a switch taken, and what follows it a turn later (pins matched to the
    row, the page in front woken) in. Waited for, not slept through."""
    deadline = time.monotonic() + within
    last = None
    while True:
        state = sv.sp("state", window=window)
        look = (state["spaceID"], state["activeID"], [tab["id"] for tab in state["tabs"]], state["everywhere"])
        if (done(state) and look == last) or time.monotonic() > deadline:
            return state
        last = look
        time.sleep(0.05)


def space(action, window=1, **fields):
    before = sv.sp("state", window=window)
    command("space", action=action, window=window, **fields)
    if action == "go":
        target = before["spaceIDs"][fields["index"] - 1]
        return settled(window, lambda state: state["spaceID"] == target)
    if action == "new":
        return settled(window, lambda state: len(state["spaceIDs"]) > len(before["spaceIDs"])
                       and state["spaceID"] == state["spaceIDs"][-1])
    return settled(window, lambda state: before["spaceID"] not in state["spaceIDs"])


def select(tab):
    command("select", id=tab)


def shared(state):
    return next(tab for tab in state["tabs"] if tab["id"] in state["everywhere"])


def front(state):
    return next(tab for tab in state["tabs"] if tab["id"] == state["activeID"])


def previously_loaded_pin(t, go_home):
    mode = "pins go home" if go_home else "pins stay"
    sv.setup(spaces=True, **{"pins.home": go_home, "float.leave": False})
    sv.launch()
    sv.page("loose")
    pin = sv.page("home")
    command("pin", id=pin)
    command("pin", id=pin, everywhere=True)
    command("go", id=pin, url=sv.BASE + "/old-article")
    command("wait", id=pin)
    sv.ev(pin, "window.oldDocument = true")
    space("new", name="Two")
    sv.page("other")
    chosen = shared(sv.sp("state"))["id"]
    select(chosen)
    command("go", id=chosen, url=sv.BASE + "/current-article")
    command("wait", id=chosen)
    command("settings", set=KEY, value=True)
    followed = shared(space("go", index=1))
    t.ok(f"{mode}: turned on, the page in front follows to the other space", followed["id"] == chosen, followed)
    sv.sp("close", id=chosen)
    closed = shared(sv.sp("state"))
    t.ok(f"{mode}: closed, the pin is asleep", closed["asleep"], closed)
    reopened = shared(space("go", index=2))
    select(reopened["id"])
    command("wait", id=reopened["id"])
    expected = "/home" if go_home else "/current-article"
    woke = sv.ev(reopened["id"], "[location.pathname, !!window.oldDocument]")
    t.ok(f"{mode}: it wakes as the page that followed, not the one left behind", woke == [expected, False], woke)
    # The page the first space had gave way to the one that followed: put
    # down then, not left running in whichever space isn't on screen. With
    # the setting off each space shows its own again, so it can be looked at.
    command("settings", set=KEY, value=False)
    left = shared(space("go", index=1))
    select(left["id"])
    command("wait", id=left["id"])
    kept = sv.ev(left["id"], "!!window.oldDocument")
    t.ok(f"{mode}: the page it took the place of was put to sleep", left["id"] == pin and kept is False,
         (pin, left, kept))


def case_previously_loaded_pin_goes_home(t):
    """a pin with a page in two spaces before the setting is turned on, pins going home"""
    previously_loaded_pin(t, go_home=True)


def case_previously_loaded_pin_stays(t):
    """a pin with a page in two spaces before the setting is turned on, pins staying where they are"""
    previously_loaded_pin(t, go_home=False)


def case_same_url_and_restart(t):
    """two pins at one address, a space not yet gone to, and a restart"""
    sv.setup(spaces=True, **{KEY: True, "start.fresh": False})
    sv.launch()
    command("window")
    pins = []
    for marker in ["first", "second"]:
        tab = sv.page("same-url")
        command("pin", id=tab)
        command("pin", id=tab, everywhere=True)
        sv.ev(tab, f"window.name = '{marker}'")
        pins.append(tab)
    views = {x["id"]: x["web"] for x in sv.sp("state")["tabs"] if x["id"] in pins}
    cold = space("new", name="Second")
    t.ok("a space not yet gone to opens on an empty tab", front(cold)["blank"], front(cold))
    there = {x["id"]: x["web"] for x in cold["tabs"] if x["id"] in pins}
    t.ok("two pins at one address each bring their own page", there == views, (views, there))
    names = [sv.ev(tab, "window.name") for tab in pins]
    t.ok("…and their own document", names == ["first", "second"], names)
    sv.page("second-loose")
    back = space("go", index=1)
    t.ok("the first space still has its pin in front", back["activeID"] == pins[1], back["activeID"])
    sv.sp("save")
    sv.quit()
    sv.launch()
    restored = sv.sp("state")
    active = restored["activeID"]
    t.ok("after a restart the pin is in front again", active == restored["everywhere"][1],
         (active, restored["everywhere"]))
    web = next(x["web"] for x in restored["tabs"] if x["id"] == active)
    t.ok("…with its page", bool(web), web)
    second = space("go", index=2)
    t.ok("the second space has its own tab in front", front(second)["url"].endswith("/second-loose"), front(second))
    same = next(x["web"] for x in second["tabs"] if x["id"] == active)
    t.ok("…and the pin there is the same page", same == web, (web, same))


def restart_in_a_separate_space(t, reuse, go_home):
    mode = f"reuse {'on' if reuse else 'off'}, {'pins go home' if go_home else 'pins stay'}"
    sv.setup(spaces=True, **{KEY: reuse, "pins.home": go_home, "pins.peek": go_home, "start.fresh": False})
    sv.launch()
    command("window")
    pin = sv.page("home")
    command("pin", id=pin)
    command("pin", id=pin, everywhere=True)
    space("new", name="Second")
    separate = space("new", name="Separate", fresh=True)["spaceID"]
    command("windows", action="new")
    # Each window owns a different page, in a different space, for the same pin.
    for window, owner in [(1, 2), (2, 1)]:
        space("go", window=window, index=3 - owner)
        sv.sp("open", url=sv.BASE + "/loose", window=window)
        tab = shared(space("go", window=window, index=owner))["id"]
        command("select", id=tab, window=window)
        command("go", id=tab, url=sv.BASE + f"/watch-{window}", window=window)
        command("wait", id=tab, window=window)
        space("go", window=window, index=3)
        sv.sp("save", window=window)
    sv.quit()
    sv.launch()
    for window, owner in [(1, 2), (2, 1)]:
        where = f"{mode}, window {window}"
        came = sv.sp("state", window=window)["spaceID"]
        t.ok(f"{where}: back in the separate space", came == separate, (came, separate))
        documents = []
        # Both windows go to space 1, then 2. Window 1 left its page in
        # space 2, so it meets the space that doesn't hold it first; window
        # 2, the one that does.
        for index in (1, 2):
            state = space("go", window=window, index=index)
            pin = shared(state)
            ahead = front(state)
            if index == owner:
                t.ok(f"{where}, space {index}: the pin is in front, as it was left", ahead["id"] == pin["id"], ahead)
            else:
                t.ok(f"{where}, space {index}: its own tab is in front", ahead["url"].endswith("/loose"), ahead)
            command("select", id=pin["id"], window=window)
            command("wait", id=pin["id"], window=window)
            path = command("eval", id=pin["id"], js="location.pathname", window=window)["value"]
            expected = f"/watch-{window}" if not go_home and (reuse or index == owner) else "/home"
            t.ok(f"{where}, space {index}: the pin is at {expected}", path == expected, path)
            page = shared(sv.sp("state", window=window))
            t.ok(f"{where}, space {index}: the pin has a page", bool(page["web"]), page)
            documents.append((page["id"], page["web"]))
            seen = command("eval", id=pin["id"], window=window,
                           js="(() => { const seen = !!window.revisited; window.revisited = true; return seen })()")["value"]
            again = reuse and len(documents) == 2
            t.ok(f"{where}, space {index}: {'the document seen before' if again else 'a document not seen before'}",
                 seen == again, seen)
        t.ok(f"{where}: {'one page for both spaces' if reuse else 'a page for each space'}",
             (documents[0] == documents[1]) == reuse, documents)


def case_restart_in_a_separate_space(t):
    """a restart in a space with separate sign-ins, two windows each with a page of the pin"""
    restart_in_a_separate_space(t, reuse=True, go_home=False)


def case_restart_in_a_separate_space_pins_go_home(t):
    """the same restart, pins going home"""
    restart_in_a_separate_space(t, reuse=True, go_home=True)


def case_restart_in_a_separate_space_reuse_off(t):
    """the same restart with the setting off"""
    restart_in_a_separate_space(t, reuse=False, go_home=False)


def case_live_page_past_a_separate_space(t):
    """a page left running in one space, a space with separate sign-ins gone through, then the next"""
    sv.setup(spaces=True, **{KEY: True, "float.leave": False})
    sv.launch()
    command("window")
    pin = sv.page("home")
    command("pin", id=pin)
    command("pin", id=pin, everywhere=True)
    sv.ev(pin, "window.marker = 'live'")
    web = shared(sv.sp("state"))["web"]
    space("new", name="Second")
    sv.page("loose")
    space("go", index=1)
    select(pin)
    apart = shared(space("new", name="Separate", fresh=True))
    t.ok("the space with separate sign-ins has a tab of its own", apart["id"] != pin and apart["web"] != web, apart)
    # Straight from the separate space: the page is still in the first
    # space's row, parked, and comes from there.
    there = shared(space("go", index=2))
    t.ok("from there, the next space signed in with the first has the page", there["id"] == pin and there["web"] == web,
         (pin, web, there))
    select(pin)
    marker = sv.ev(pin, "window.marker")
    t.ok("…the same document", marker == "live", marker)
    back = space("go", index=1)
    t.ok("…and the first space has it again, in front as it was left",
         shared(back)["web"] == web and back["activeID"] == pin, (back["activeID"], shared(back)))


def case_page_moved_while_away(t):
    """the pin's page goes on to another while a space with separate sign-ins is on screen, then a restart"""
    sv.setup(spaces=True, **{KEY: True, "pins.home": False, "pins.peek": False, "start.fresh": False})
    sv.launch()
    command("window")
    pin = sv.page("home")
    command("pin", id=pin)
    command("pin", id=pin, everywhere=True)
    space("new", name="Second")
    sv.page("loose")
    space("go", index=1)
    select(pin)
    # As a playlist goes on to its next video with nobody looking. A parked
    # row's tabs aren't the bench's to ask, so the page takes itself there.
    sv.ev(pin, "setTimeout(() => { location.href = '/next-video' }, 1500); true")
    separate = space("new", name="Separate", fresh=True)["spaceID"]
    time.sleep(4)
    # The row on screen is the separate space's: the row holding the page
    # was written as it was left, at /home, and only quitting writes it again.
    sv.quit()
    sv.launch()
    came = sv.sp("state")["spaceID"]
    t.ok("back in the separate space", came == separate, (came, separate))
    for index in (2, 1):
        there = shared(space("go", index=index))
        select(there["id"])
        command("wait", id=there["id"])
        path = sv.ev(there["id"], "location.pathname")
        t.ok(f"space {index}: the pin is where its page went while away", path == "/next-video", path)


def case_deletion_and_what_stays_apart(t):
    """a space deleted under the page, and what never shares it"""
    sv.setup(spaces=True, **{KEY: True})
    sv.launch()
    command("window")
    pin = sv.page("source")
    command("pin", id=pin)
    command("pin", id=pin, everywhere=True)
    sv.ev(pin, "document.cookie = 'login=shared;path=/'; window.marker = 'survivor'")
    original = shared(sv.sp("state"))["web"]
    space("new", name="Deleted while visible")
    # The new window has never switched spaces. Its own live document
    # must survive when the first window deletes the space both show.
    command("windows", action="front", n=1)
    command("windows", action="new")
    copy = shared(sv.sp("state", window=2))["id"]
    command("select", id=copy, window=2)
    command("wait", id=copy, window=2)
    command("eval", id=copy, window=2, js="window.marker = 'second window'")
    space("delete")
    moved = shared(sv.sp("state", window=2))
    marker = command("eval", id=copy, window=2, js="window.marker")["value"]
    t.ok("its space deleted in another window, a window keeps its page of the pin",
         moved["id"] == copy and marker == "second window", (copy, moved, marker))
    command("windows", action="close", n=2)
    space("new", name="Survives")
    space("go", index=1)
    separate = shared(space("new", name="Separate", fresh=True))["id"]
    select(separate)
    command("wait", id=separate)
    apart = sv.ev(separate, "[window.marker || null, document.cookie]")
    t.ok("a space with separate sign-ins has a page and cookies of its own", apart == [None, ""], apart)
    sv.ev(separate, "document.cookie = 'login=separate;path=/'; window.marker = 'separate'")
    command("windows", action="new")
    time.sleep(1)
    space("go", index=1, window=2)
    copy = shared(sv.sp("state", window=2))["id"]
    command("select", id=copy, window=2)
    command("wait", id=copy, window=2)
    other = shared(sv.sp("state", window=2))["web"]
    t.ok("another window has a page of its own", other != original, (original, other))
    space("delete", window=2)
    apart = sv.ev(separate, "[window.marker, document.cookie]")
    t.ok("the space holding the page deleted elsewhere, the separate space is untouched",
         apart == ["separate", "login=separate"], apart)
    survivor = shared(space("go", index=1))["web"]
    t.ok("…and the page is in a space that is left", survivor == original, (original, survivor))
    select(pin)
    kept = sv.ev(pin, "[window.marker, document.cookie]")
    t.ok("…as it was", kept == ["survivor", "login=shared"], kept)

    command("profile", action="new", name="Other profile")
    command("profile", action="window", name="Other profile")
    time.sleep(1)
    theirs = sv.sp("state", window=3)["everywhere"]
    t.ok("another profile has none of these pins", not theirs, theirs)
    other = sv.sp("open", url=sv.BASE + "/source", window=3)["resultID"]
    command("wait", id=other, window=3)
    command("pin", id=other, window=3)
    command("pin", id=other, everywhere=True, window=3)
    view = shared(sv.sp("state", window=3))["web"]
    marker = command("eval", id=other, js="window.marker || null", window=3).get("value")
    t.ok("its own pin at the same address is another page", view != original and marker is None, (view, marker))
    mine = sv.ev(pin, "window.marker")
    t.ok("…and this profile's is as it was", mine == "survivor", mine)


def case_toggle_and_unshare(t):
    """the setting switched with a page already open, and a pin kept by one space again"""
    sv.setup(spaces=True, **{"float.leave": False})
    sv.launch()
    command("window")
    space("new", name="Second")
    other = sv.page("other")
    space("go", index=1)
    pin = sv.page("home")
    command("pin", id=pin)
    command("pin", id=pin, everywhere=True)
    sv.ev(pin, "window.marker = 'original'")
    own = shared(space("go", index=2))
    t.ok("off, the other space has a tab of its own for the pin", own["id"] != pin, own)
    command("settings", set=KEY, value=True)
    state = settled(done=lambda state: shared(state)["id"] == pin, within=3)
    t.ok("turned on, the open page comes to the space on screen", shared(state)["id"] == pin, shared(state))
    t.ok("…behind the tab in front, which stays", state["activeID"] == other, state["activeID"])
    select(pin)
    marker = sv.ev(pin, "window.marker")
    t.ok("…the same document", marker == "original", marker)
    command("pin", id=pin, everywhere=False)
    elsewhere = space("go", index=1)["everywhere"]
    t.ok("kept by this space alone, the other spaces have it no more", not elsewhere, elsewhere)
    space("go", index=2)
    marker = sv.ev(pin, "window.marker")
    t.ok("…and this space still has its page", marker == "original", marker)
    command("pin", id=pin, everywhere=True)
    command("settings", set=KEY, value=False)
    here = shared(sv.sp("state"))
    t.ok("turned off, the page stays where it is", here["id"] == pin, here)
    apart = shared(space("go", index=1))
    t.ok("…and the other space has a tab of its own again", apart["id"] != pin, apart)


def held_short():
    """Two fingers towards the space before, not yet let go, as space_landing.py
    looks at a folded group: the bench's answer, and in it that space as the
    swipe draws it ("drawn"). The only space parked: there are two."""
    answer = command("space", action="hold", dx=15)
    return answer, next(iter(answer.get("drawn", {}).values()), {})


def let_go(t, where, state):
    command("space", action="release")
    time.sleep(0.6)
    t.ok(f"{where}: let go short of it, the window stays where it was", sv.sp("state")["spaceID"] == state["spaceID"])


def drawn_on_the_way_in(t, sidebar):
    where = "in the column" if sidebar else "across the top"
    sv.setup(spaces=True, sidebar=sidebar, **{KEY: True, "float.leave": False})
    sv.launch()
    command("window")
    pin = sv.page("home")
    command("pin", id=pin)
    command("pin", id=pin, everywhere=True)
    space("new", name="Second")
    select(pin)
    state = settled(done=lambda state: state["activeID"] == pin)
    t.ok(f"{where}: the pin's page is in front in both spaces", shared(state)["id"] == pin and state["activeID"] == pin,
         (pin, state["activeID"], shared(state)))
    # A count in its title, for the badge on its square (Tab.unread).
    sv.ev(pin, "document.title = '(3) Home'; 1")
    time.sleep(0.3)
    # The first space's row still has the tab standing in for the pin,
    # asleep: drawn from that, the icon came in dimmed and its count gone,
    # both back as the space landed.
    held, first = held_short()
    pins = first.get("pins", [])
    t.ok(f"{where}: mid-swipe, the space coming in draws the pin as the open page",
         held.get("swipe", 0) != 0 and [p["id"] for p in pins] == [pin], held.get("drawn"))
    t.ok("…awake, so at full strength, and with its count", pins and not pins[0]["asleep"] and pins[0]["unread"] == "3", pins)
    t.ok("…in front, as the pin was left there", first.get("active") == pin, first)
    during = sv.sp("state")
    t.ok("…and the page stays this space's until the other is taken",
         during["spaceID"] == state["spaceID"] and shared(during)["id"] == pin, (during["spaceID"], shared(during)))
    let_go(t, where, state)
    command("settings", set=KEY, value=False)
    settled()
    held, first = held_short()
    pins = first.get("pins", [])
    t.ok(f"{where}: with the setting off, it draws its own tab for the pin, asleep and with no count",
         len(pins) == 1 and pins[0]["id"] != pin and pins[0]["asleep"] and pins[0]["unread"] == "", pins)
    let_go(t, where, state)


def case_drawn_on_the_way_in_column(t):
    """a space on its way in, drawn with the page that comes with it, tabs in the column"""
    drawn_on_the_way_in(t, sidebar=True)


def case_drawn_on_the_way_in_strip(t):
    """a space on its way in, drawn with the page that comes with it, tabs across the top"""
    drawn_on_the_way_in(t, sidebar=False)


def main():
    t = sv.T()
    for case in [case_previously_loaded_pin_goes_home, case_previously_loaded_pin_stays, case_same_url_and_restart,
                 case_restart_in_a_separate_space, case_restart_in_a_separate_space_pins_go_home,
                 case_restart_in_a_separate_space_reuse_off, case_live_page_past_a_separate_space,
                 case_page_moved_while_away, case_deletion_and_what_stays_apart, case_toggle_and_unshare,
                 case_drawn_on_the_way_in_column, case_drawn_on_the_way_in_strip]:
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
