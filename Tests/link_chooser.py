#!/usr/bin/env python3
"""A link from another app opened in the space chosen for it (#1175),
checked in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/link_chooser.py`. The app
starts hidden in a world of its own (see split_view.use) with spaces on, is
driven through ./bench's socket, and is quit; its world is removed
afterwards. Local pages only, from 127.0.0.1, which no rule names until
Always saves one, and one address that goes nowhere.

Each run has Home and Family, spaces of the first profile, Home in front,
and a second profile, Work, with a space Clients and no window open, Work
last at its own first space. Each of the three is signed in apart, with a
cookie that says which it is. Once with Profiles in one window off, once on:

- a link opened in Family in a small window is sent Family's cookie from its
  first request, and Work gets no browser;
- one opened in Clients in a small window is sent Clients' cookie; Work gets
  a browser kept out of sight, and no window changes profile or is kept away;
- the next one opened as a tab brings Work's window out, at Clients;
- Open in Search on the small window moves the page to Clients, not Home,
  and doesn't load it again;
- a tab in Clients, with Home in front again, gets Clients' cookie, and
  Home's tabs stay as they were;
- a small window that a page in a Family small window opens is in Family
  too, and Open in Search moves it there;
- with Home in front, a ⌘-click in a Family small window opens a tab in
  Family, with Family's sign-ins, and so do Open Link in New Tab and a
  middle-click;
- with Clients deleted, Open in Search on a small window of it opens no tab,
  and asks again which space, for the page's address;
- a space that isn't there opens nothing, and the opener says so.

Then, with a rule sending localhost to Home and Home on screen, Open Link
in New Tab and a target=_blank click in a Family small window, to
localhost, each open a tab in Home with Home's sign-ins, not in Family and
not as a small window.

Then, once each way again, with the browser's windows kept away as a link's
small window keeps them in a hidden app (a cold launch or ⌘H): a small
window in Clients keeps them away; Open in Search on it brings them back,
with the page in Clients; so does a tab in Clients. And once each way, a
⌘-click in a small window of Work's first space, where Work's browser is
made out of sight, opens its tab in that browser, brought into sight; and
that browser, brought forward with the bench's `windows front` (which
reaches Browsers.becameKey without `show`), is a window like any other from
then on.

Last, with Profiles in one window off: Work's browser kept out of sight
stays so after a relaunch; with the setting then turned on, a tab in Clients
brings that browser, with Work's tabs, not a second one.

Then the chooser itself, which the bench works without its panel, links
opening in small windows and Send links to a space on:

- it lists every space of both profiles in the Spaces menu's order, numbered
  1 on, and marks the space in front for a site never chosen;
- Esc and ⌘W open nothing; ⌘2 opens nothing and the link still waits, as
  it does with 2 held down, while ↓ held down walks on;
- 2 opens the link at once in Family, with Family's sign-ins;
- ↓ and the keypad's Return, with the flags their events carry, move the
  mark and open the link;
- once Clients is chosen for 127.0.0.1, the next link there has Clients
  marked, and Return opens it in Clients;
- a link with no site offers no Always, and choosing remembers nothing;
- Family deleted while it is marked: Return opens nothing, says the space
  is gone, lists the spaces left, and the link still waits;
- with spaces turned off, Open in Search on a small window of Clients
  leaves it as it is, and asks nothing.

With Send links to a space on, Space then 2 saves 127.0.0.1 to Family and
opens a tab there, though links open in small windows. With it off and links
opening in tabs, no Always, Space changes nothing, and 2 opens a tab in Family.

Then links handed over as macOS hands them, in a probe hidden as ⌘H leaves
the app, with Ask which space on unless said:

- a link to localhost, which a rule sends to Family, opens there unasked;
- one to 127.0.0.1 is asked about, under the name of the app it came from,
  with nothing opened, the page never asked for and the windows kept away;
  2 opens it in Family, with Family's sign-ins, and brings the windows back;
- links that come while one waits are asked about in turn, after a choice
  and after Esc, and only the one chosen is asked for;
- with Go to the open page on, a link to a page open in a tab brings the tab
  forward and asks nothing; one open nowhere is asked about;
- never turned on, a link opens in its small window as before, and
  clearing history writes no memory of where links went;
- with one space in all, a link opens in its small window, unasked;
- an email link is asked about as Gmail's compose page, which loads only
  once chosen; switched off, it opens in a tab as before;
- a link that launches the app is asked about with every space listed and
  the space chosen last marked, every window kept away and nothing loaded;
  2 opens it in Family and brings the windows back, Esc leaves them away.

Nothing is ever ordered onto a screen: a hidden probe's windows are only
ordered out, never in, and after the steps that make a browser or bring one
back, every window is checked to be off screen.
"""
import plistlib
import subprocess
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import parse_qs, urlparse, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("link-chooser")
first = {}  # path -> the Cookie header its first request was sent
hits = {}  # path -> how many times it was asked for


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlparse(self.path).path
        first.setdefault(path, self.headers.get("Cookie") or "")
        hits[path] = hits.get(path, 0) + 1
        # A page that opens a window of its own as it loads (pop-ups are
        # allowed for 127.0.0.1, see seed), and pages with links to click,
        # each where the test knows to find it: on this site, or on
        # localhost, which a rule can name, the first in a new window as
        # target=_blank asks.
        opens = "<script>window.open(location.pathname.replace('-opens', '-second'))</script>" if path.endswith("-opens") else ""
        if path.endswith("-links"):
            links = anchors(path, ["tab", "menu", "middle"])
        elif path.endswith("-ruled"):
            links = anchors(f"http://localhost:{self.server.server_port}{path}", ["blank", "menu"], blank="blank")
        else:
            links = ""
        data = f"<!doctype html><meta charset=utf-8><title>{path}</title>{path}{opens}{links}".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Cache-Control", "no-store")
        who = parse_qs(urlparse(self.path).query).get("who")
        if who:
            self.send_header("Set-Cookie", f"who={who[0]}; Path=/; Max-Age=3600")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


def anchors(base, names, blank=None):
    """A link to base-name for each name, one under the other."""
    return "".join(f"<a id={name}{' target=_blank' if name == blank else ''} href={base}-{name} "
                   f"style='position:fixed;left:0;top:{200 * n}px;width:400px;height:150px'>{name}</a>"
                   for n, name in enumerate(names))


sv.srv.RequestHandlerClass = H


def c(req, window=None):
    return sv.cmd({**req, "window": window} if window else req)


def windows(): return c({"do": "windows"})
def little(what="look"): return c({"do": "little", "what": what})
def space(action, window=None, **f): return c({"do": "space", "action": action, **f}, window)


def open_tab(url, window=None):
    c({"do": "split", "action": "open", "url": url}, window)
    time.sleep(1.2)


def link(url, sender=None):
    """A link from another app, as macOS hands it over: from `sender`, by
    the app's name, when the event says."""
    c({"do": "windows", "action": "link", "url": url, "sender": sender})


def link_in(url, space_id, small):
    """The opener, as the chooser calls it once a space is picked."""
    return c({"do": "windows", "action": "link-in", "url": url, "space": space_id, "little": small}).get("opened")


# Key codes, as the panel reads them whatever the layout.
ONE, TWO, FIVE, RETURN, KEYPAD_RETURN, DOWN, UP, SPACE_BAR, ESC, W_KEY = 18, 19, 23, 36, 76, 125, 126, 49, 53, 13


def chooser(action="look", **f): return c({"do": "chooser", "action": action, **f})
def ask(url): return chooser("ask", url=url)
def marked(st): return next((r["name"] for r in st.get("rows", []) if r["picked"]), None)


def key(code, *flags, chars="", repeat=False):
    """A key down on the panel, as its monitor hands it over: the flags held
    ("cmd", or the "numericPad" and "function" an arrow's event carries),
    what it types, and whether it is a key held down."""
    return chooser("key", code=code, flags=list(flags), chars=chars, repeat=repeat)


def stored(name):
    """A setting as the app last saved it."""
    out = subprocess.run(["defaults", "export", sv.SUITE, "-"], capture_output=True, check=True).stdout
    return plistlib.loads(out).get(name)


def sent(path, within=6):
    """The Cookie header the first request for `path` carried, once it came."""
    until = time.time() + within
    while path not in first and time.time() < until:
        time.sleep(0.1)
    return first.get(path)


def window_in(ws, name): return next((w for w in ws if w["space"] == name), {})
def every_tab(ws): return [u for w in ws for u in w["tabs"]]


def off_screen(t, label):
    shown = [w for w in windows()["windows"] if w["shown"]]
    t.ok(f"no window on screen ({label})", not shown, shown)


class World:
    def __init__(self, tag, clients, family, work):
        self.tag, self.clients, self.family, self.work = tag, clients, family, work

    def url(self, name): return f"{sv.BASE}/{self.tag}-{name}"
    def path(self, name): return f"/{self.tag}-{name}"
    # localhost, the site a rule can name: the same server.
    def ruled(self, name): return f"http://localhost:{sv.srv.server_port}/{self.tag}-{name}"


def seed(t, tag, one_window, small_windows=False, sends_links=False, more=None):
    sv.setup(**{"spaces": True, "links.little": small_windows, "spaces.links": sends_links, **(more or {})})
    subprocess.run(["defaults", "write", sv.SUITE, "privacy.popupSites", "-array", "127.0.0.1"], check=True)
    sv.launch()
    space("new", name="Family", fresh=True); time.sleep(0.8)
    open_tab(f"{sv.BASE}/set?who=family")
    space("new", name="Home", fresh=True); time.sleep(0.8)
    open_tab(f"{sv.BASE}/set?who=home")
    family = next(s["id"] for s in space("list")["spaces"] if s["name"] == "Family")
    c({"do": "profile", "action": "new", "name": "Work"}); time.sleep(0.8)
    c({"do": "profile", "action": "window", "name": "Work"}); time.sleep(1)
    space("new", window=2, name="Clients", fresh=True); time.sleep(0.8)
    open_tab(f"{sv.BASE}/set?who=clients", window=2)
    listed = space("list", window=2)["spaces"]
    clients = next(s["id"] for s in listed if s["name"] == "Clients")
    work = next(s["id"] for s in listed if s["name"] == "Work")
    # Work last at its first space, not Clients: a browser of Work made
    # later starts there, so the chosen space is what puts a page in Clients.
    space("go", window=2, index=1); time.sleep(0.8)
    c({"do": "windows", "action": "close", "n": 2}); time.sleep(1)
    c({"do": "windows", "action": "front", "n": 1})
    # Turned on only now: on while Work's window was made, it would have
    # merged with the first one, and closing it would have kept it.
    c({"do": "settings", "set": "profiles.oneWindow", "value": one_window})
    ws = windows()["windows"]
    t.ok("Home in front, and no window of Work",
         [(w["profile"], w["space"], w["front"]) for w in ws] == [("Personal", "Home", True)], ws)
    return World(tag, clients, family, work)


def work_browsers(ws): return [x for x in ws if x["profile"] == "Work"]


def test_link_in_small_window_same_profile_uses_chosen_space(t, w):
    opened = link_in(w.url("family"), w.family, True)
    st = little()
    t.ok("a small window in Family, with Home in front", opened is True and st.get("space") == [w.family], st)
    t.ok("with Family's sign-ins from its first request", sent(w.path("family")) == "who=family", first)
    ws = windows()["windows"]
    t.ok("and no browser of Work", not work_browsers(ws) and window_in(ws, "Home").get("front"), ws)
    little("close"); time.sleep(0.5)


def test_link_in_small_window_uses_chosen_space(t, w):
    before = windows()
    opened = link_in(w.url("little"), w.clients, True)
    st = little()
    t.ok("a small window", opened is True and st["littles"] == [w.url("little")], (opened, st["littles"]))
    t.ok("in Clients", st.get("space") == [w.clients], st.get("space"))
    t.ok("with Clients' sign-ins from its first request", sent(w.path("little")) == "who=clients", first)
    after = windows()
    look = lambda state: [(x["profile"], x["front"], x["away"]) for x in state["windows"][:len(before["windows"])]]
    t.ok("no window changes profile, or is kept away", look(after) == look(before) and not after["keptAway"],
         (look(before), look(after), after["keptAway"]))
    work = work_browsers(after["windows"])
    t.ok("Work gets a browser, out of sight",
         len(work) == 1 and work[0]["tucked"] and not work[0]["open"] and not work[0]["inWindowMenu"], work)
    t.ok("at Work's last space, not Clients: the choice put the page there",
         len(work) == 1 and work[0]["space"] != "Clients", work)
    off_screen(t, "Work's browser made")


def test_tab_after_small_window_is_on_screen(t, w):
    opened = link_in(w.url("after"), w.clients, False)
    ws = windows()["windows"]
    target = window_in(ws, "Clients")
    t.ok("then a tab brings Work's window out, at Clients",
         opened is True and target.get("profile") == "Work" and target.get("open") and not target.get("tucked")
         and not target.get("away") and target.get("inWindowMenu"), target)
    t.ok("the same one, not a second", [x["profile"] for x in ws].count("Work") == 1, ws)
    off_screen(t, "Work's window brought out")


def test_keep_keeps_chosen_space(t, w):
    little("keep"); time.sleep(1)
    ws = windows()["windows"]
    t.ok("Open in Search moves the page to Clients",
         w.url("little") in window_in(ws, "Clients").get("tabs", []) and little()["littles"] == [], ws)
    t.ok("not to Home", w.url("little") not in window_in(ws, "Home").get("tabs", []), window_in(ws, "Home"))
    t.ok("and doesn't load it again", hits.get(w.path("little")) == 1, hits.get(w.path("little")))


def test_link_in_tab_uses_chosen_space(t, w):
    # Home in front again, not Work's window at Clients: the tab has to be
    # sent there.
    c({"do": "windows", "action": "front", "n": 1}); time.sleep(0.5)
    home = window_in(windows()["windows"], "Home")
    opened = link_in(w.url("tab"), w.clients, False); time.sleep(1)
    ws = windows()["windows"]
    t.ok("a tab in Clients", opened is True and w.url("tab") in window_in(ws, "Clients").get("tabs", []), ws)
    t.ok("with Clients' sign-ins from its first request", sent(w.path("tab")) == "who=clients", first)
    kept = lambda x: (x.get("n"), x.get("profile"), x.get("tabs"))
    t.ok("Home as it was", kept(window_in(ws, "Home")) == kept(home), (home, window_in(ws, "Home")))


def test_window_a_page_opens_keeps_chosen_space(t, w):
    # Family, which no window shows: what the page opens has to take the
    # chosen space with it.
    link_in(w.url("opens"), w.family, True); time.sleep(2)
    st = little()
    t.ok("a page in a Family small window opens another, in Family",
         st["littles"][-1:] == [w.url("second")] and st.get("space", [])[-1:] == [w.family], st)
    t.ok("with Family's sign-ins", sent(w.path("second")) == "who=family", first)
    little("keep"); time.sleep(1)
    ws = windows()["windows"]
    t.ok("Open in Search on that one moves it to Family",
         w.url("second") in window_in(ws, "Family").get("tabs", []), ws)
    little("close"); time.sleep(0.5)


def test_new_tabs_from_small_window_keep_chosen_space(t, w):
    # Home in front and no window at Family: the tabs have to be sent there.
    def home_in_front():
        c({"do": "windows", "action": "front", "n": 1}); space("go", index=3); time.sleep(0.8)
        ws = windows()["windows"]
        return window_in(ws, "Home").get("front") and not window_in(ws, "Family"), ws
    link_in(w.url("links"), w.family, True); time.sleep(1.5)
    t.ok("Home in front, and no window at Family", *home_in_front())
    c({"do": "tap", "little": True, "selector": "#tab", "mods": ["cmd"]}); time.sleep(1.5)
    t.ok("a ⌘-click in a Family small window opens a tab with Family's sign-ins",
         sent(w.path("links-tab")) == "who=family", first)
    t.ok("in Family", w.url("links-tab") in window_in(windows()["windows"], "Family").get("tabs", []), windows())
    t.ok("Home in front again, and no window at Family", *home_in_front())
    c({"do": "linkmenu", "little": True, "x": 100, "y": 300, "pick": "Open Link in New Tab"}); time.sleep(1.5)
    ws = windows()["windows"]
    t.ok("Open Link in New Tab there opens a tab in Family, not Home",
         w.url("links-menu") in window_in(ws, "Family").get("tabs", []) and every_tab(ws).count(w.url("links-menu")) == 1, ws)
    t.ok("Home in front again, and no window at Family", *home_in_front())
    c({"do": "tap", "little": True, "selector": "#middle", "button": "middle"}); time.sleep(1.5)
    ws = windows()["windows"]
    t.ok("and so does a middle-click, with Family's sign-ins",
         w.url("links-middle") in window_in(ws, "Family").get("tabs", []) and sent(w.path("links-middle")) == "who=family",
         (ws, first))
    little("close"); time.sleep(0.5)


def test_ruled_site_from_small_window_opens_in_its_space(t, w):
    # Home on screen, and a small window in Family: the rule's space, not
    # the window's or the chosen one, is where its site opens.
    link_in(w.url("ruled"), w.family, True); time.sleep(1.5)
    ws = windows()["windows"]
    t.ok("Home on screen, and a small window in Family",
         [x["space"] for x in ws] == ["Home"] and little().get("space") == [w.family], (ws, little()))
    c({"do": "linkmenu", "little": True, "x": 100, "y": 300, "pick": "Open Link in New Tab"}); time.sleep(1.5)
    ws = windows()["windows"]
    t.ok("Open Link in New Tab there, to a site a rule sends to Home: a tab in Home, with Home's sign-ins",
         w.ruled("ruled-menu") in window_in(ws, "Home").get("tabs", []) and sent(w.path("ruled-menu")) == "who=home",
         (ws, first))
    c({"do": "tap", "little": True, "selector": "#blank"}); time.sleep(1.5)
    st = windows()
    t.ok("a target=_blank click there: a tab in Home too, with Home's sign-ins",
         w.ruled("ruled-blank") in window_in(st["windows"], "Home").get("tabs", [])
         and sent(w.path("ruled-blank")) == "who=home", (st, first))
    t.ok("not a small window in Family", st["littles"] == [w.url("ruled")], st["littles"])
    little("close"); time.sleep(0.5)


def test_new_tab_from_other_profile_comes_into_sight(t, w):
    # Work's first space, where Work's browser is made out of sight for the
    # small window: it shows that space already, but nobody sees it.
    link_in(w.url("links"), w.work, True); time.sleep(1.5)
    work = work_browsers(windows()["windows"])
    t.ok("a small window in Work, Work's browser out of sight there",
         len(work) == 1 and work[0]["tucked"] and work[0]["space"] == "Work", work)
    c({"do": "tap", "little": True, "selector": "#tab", "mods": ["cmd"]}); time.sleep(1.5)
    work = work_browsers(windows()["windows"])
    t.ok("a ⌘-click there opens a tab in Work's window, brought into sight",
         len(work) == 1 and work[0]["open"] and not work[0]["tucked"] and w.url("links-tab") in work[0]["tabs"], work)
    off_screen(t, "Work's window brought into sight")
    little("close"); time.sleep(0.5)


def test_brought_forward_comes_into_sight(t, w):
    link_in(w.url("little"), w.clients, True); time.sleep(1)
    work = work_browsers(windows()["windows"])
    t.ok("Work's browser out of sight for a small window", len(work) == 1 and work[0]["tucked"], work)
    # As its window becoming key would have it, for whatever brought it.
    c({"do": "windows", "action": "front", "n": work[0]["n"]}); time.sleep(0.5)
    work = work_browsers(windows()["windows"])
    t.ok("brought forward by something else, it is a window like any other",
         len(work) == 1 and not work[0]["tucked"] and work[0]["open"] and work[0]["inWindowMenu"], work)
    off_screen(t, "Work's browser brought forward")
    little("close"); time.sleep(0.5)


def test_relaunch_keeps_it_out_of_sight(t, w):
    link_in(w.url("little"), w.clients, True); time.sleep(1)
    before = work_browsers(windows()["windows"])
    t.ok("before a relaunch, Work's browser is out of sight",
         len(before) == 1 and before[0]["tucked"] and not before[0]["open"], before)
    sv.quit(); time.sleep(1)
    sv.launch(); time.sleep(1)
    after = work_browsers(windows()["windows"])
    t.ok("after it, still out of sight",
         len(after) == 1 and after[0]["tucked"] and not after[0]["open"] and not after[0]["inWindowMenu"], after)
    off_screen(t, "relaunch")


def test_one_window_turned_on_brings_it(t, w):
    c({"do": "settings", "set": "profiles.oneWindow", "value": True})
    opened = link_in(w.url("joined"), w.clients, False); time.sleep(1)
    ws = windows()["windows"]
    work = work_browsers(ws)
    t.ok("Profiles in one window turned on, then a tab in Clients: Work's one browser, with Work's tabs",
         opened is True and len(work) == 1 and not work[0]["tucked"] and work[0]["space"] == "Clients"
         and {w.url("joined"), f"{sv.BASE}/set?who=clients"} <= set(work[0]["tabs"]), ws)


def test_keep_with_gone_space_asks_again(t, w):
    link_in(w.url("gone"), w.clients, True); time.sleep(1)
    # Work's window, at Clients since the tab before.
    left = space("delete", window=window_in(windows()["windows"], "Clients").get("n")); time.sleep(1)
    t.ok("Clients deleted", "Clients" not in [s["name"] for s in left.get("spaces", [])], left.get("spaces"))
    little("keep"); time.sleep(1)
    t.ok("then Open in Search opens no tab", w.url("gone") not in every_tab(windows()["windows"]),
         windows()["windows"])
    st = chooser()
    t.ok("it asks again which space, for the page's address", st.get("shown") and st.get("url") == w.url("gone"), st)
    t.ok("and the small window goes", w.url("gone") not in little()["littles"], little()["littles"])
    key(ESC)


def test_link_in_gone_space_opens_nothing(t, w):
    before = windows()
    answers = [link_in(w.url("nowhere"), gone, small)
               for gone in (str(uuid.uuid4()), w.clients) for small in (True, False)]
    time.sleep(1)
    after = windows()
    t.ok("a space that isn't there: the opener says so", answers == [False] * 4, answers)
    t.ok("and opens nothing", every_tab(after["windows"]) == every_tab(before["windows"])
         and after["littles"] == before["littles"] and w.path("nowhere") not in hits,
         (before["littles"], after["littles"]))


def away(st):
    """Every window kept off screen for a link's small window (see little_alone.py)."""
    return st["keptAway"] and all(x["away"] for x in st["windows"] if x["open"])


def test_kept_away_windows_wait_for_the_choice(t, w):
    link(w.url("plain")); time.sleep(1)
    t.ok("a small window's link keeps the windows away", away(windows()), windows())
    opened = link_in(w.url("little"), w.clients, True); time.sleep(1)
    st = windows()
    work = work_browsers(st["windows"])
    t.ok("a small window in Clients leaves them away", opened is True and away(st), st)
    t.ok("and Work's browser out of sight, not among them",
         len(work) == 1 and work[0]["tucked"] and not work[0]["away"], work)
    little("keep"); time.sleep(1)
    st = windows()
    t.ok("Open in Search brings them back", not st["keptAway"] and not any(x["away"] for x in st["windows"]), st)
    t.ok("with the page in Clients, in Work's one window",
         w.url("little") in window_in(st["windows"], "Clients").get("tabs", [])
         and [x["profile"] for x in st["windows"]].count("Work") == 1, st["windows"])
    off_screen(t, "Open in Search")
    link(w.url("plain-again")); time.sleep(1)
    t.ok("kept away again by the next small window's link", away(windows()), windows())
    opened = link_in(w.url("tab"), w.clients, False); time.sleep(1)
    st = windows()
    target = window_in(st["windows"], "Clients")
    t.ok("a tab in Clients brings them back", opened is True and not st["keptAway"]
         and not target.get("away") and w.url("tab") in target.get("tabs", []), st)
    off_screen(t, "a tab in Clients")


# Both profiles' spaces, as the Spaces menu lists them: Work's first space
# is named for it.
ROWS = ["Personal", "Family", "Home", "Work", "Clients"]


def opened_nothing(before, path):
    # A page asked for by mistake takes a moment to reach the server.
    time.sleep(1)
    after = windows()
    return (every_tab(after["windows"]) == every_tab(before["windows"])
            and after["littles"] == before["littles"] and path not in hits)


def test_look_lists_rows_in_menu_order_with_digits(t, w):
    st = ask(w.url("look"))
    t.ok("a link waits, under its title and its address as a tab says it", st.get("shown") and st.get("url") == w.url("look")
         and st.get("title") == "Open a link" and st.get("address") == "127.0.0.1" + w.path("look"), st)
    t.ok("every space of both profiles, in the Spaces menu's order, numbered from 1",
         [(r["name"], r["digit"]) for r in st.get("rows", [])] == list(zip(ROWS, [1, 2, 3, 4, 5])), st.get("rows"))
    t.ok("a site never chosen marks the space in front", marked(st) == "Home", st.get("rows"))
    t.ok("Always is offered, off", st.get("alwaysShown") is True and st.get("always") is False, st)
    t.ok("and nothing loads before the choice", w.path("look") not in hits, hits)
    key(ESC)


def test_escape_opens_nothing(t, w):
    before = windows()
    ask(w.url("esc"))
    st = key(ESC); time.sleep(0.5)
    t.ok("Esc: no link waits", st.get("shown") is False, st)
    ask(w.url("esc"))
    st = key(W_KEY, "cmd", chars="w"); time.sleep(0.5)
    t.ok("nor after ⌘W", st.get("shown") is False, st)
    t.ok("and neither opens anything", opened_nothing(before, w.path("esc")), windows())


def test_command_digit_does_nothing(t, w):
    before = windows()
    ask(w.url("cmd"))
    st = key(TWO, "cmd"); time.sleep(0.5)
    t.ok("⌘2 opens nothing", opened_nothing(before, w.path("cmd")), windows())
    t.ok("and the link still waits", st.get("shown") and st.get("url") == w.url("cmd"), st)
    key(ESC)


def test_held_digit_opens_nothing_held_arrow_walks(t, w):
    before = windows()
    ask(w.url("held"))
    st = key(TWO, repeat=True); time.sleep(0.5)
    t.ok("a digit held down opens nothing", opened_nothing(before, w.path("held")), windows())
    t.ok("and the link still waits", st.get("shown") and st.get("url") == w.url("held"), st)
    st = key(DOWN, "numericPad", "function", repeat=True)
    t.ok("an arrow held down walks on, as in the Launcher: Home to Work", marked(st) == "Work", st.get("rows"))
    key(ESC)


def test_digit_opens_at_once(t, w):
    ask(w.url("digit"))
    st = key(TWO)
    small = little()
    t.ok("2 opens the link at once", st.get("shown") is False and small["littles"] == [w.url("digit")],
         (st, small["littles"]))
    t.ok("in Family, the second row, with its sign-ins",
         small.get("space") == [w.family] and sent(w.path("digit")) == "who=family", (small.get("space"), first))
    little("close"); time.sleep(0.5)


def test_arrow_and_keypad_return_with_their_flags(t, w):
    # An arrow's event has .numericPad and .function on, the keypad's
    # Return's .numericPad: neither is a modifier held.
    ask(w.url("pad"))
    st = key(DOWN, "numericPad", "function")
    t.ok("↓ as its event comes moves the mark from Family, chosen last, to Home", marked(st) == "Home", st.get("rows"))
    st = key(KEYPAD_RETURN, "numericPad")
    t.ok("and the keypad's Return opens the link there, with Home's sign-ins",
         st.get("shown") is False and little()["littles"] == [w.url("pad")] and sent(w.path("pad")) == "who=home",
         (st, little()["littles"], first))
    little("close"); time.sleep(0.5)


def test_return_opens_marked_last_choice(t, w):
    ask(w.url("chosen")); key(FIVE)
    little("close"); time.sleep(0.5)
    t.ok("Home still in front", window_in(windows()["windows"], "Home").get("front"), windows()["windows"])
    st = ask(w.url("again"))
    t.ok("Clients chosen for 127.0.0.1: the next link there has it marked", marked(st) == "Clients", st.get("rows"))
    st = key(RETURN)
    small = little()
    t.ok("Return opens it in Clients, with its sign-ins", st.get("shown") is False and small.get("space") == [w.clients]
         and sent(w.path("again")) == "who=clients", (st, small.get("space"), first))
    little("close"); time.sleep(0.5)


def test_no_site_hides_always(t, w):
    before = stored("links.ask.last")
    st = ask("http://no_site.invalid/")
    t.ok("a link with no site: no Always", st.get("shown") and st.get("alwaysShown") is False, st)
    key(TWO); time.sleep(0.5)
    t.ok("it opens", little()["littles"] == ["http://no_site.invalid/"], little()["littles"])
    t.ok("and choosing remembers nothing", before and stored("links.ask.last") == before,
         (before, stored("links.ask.last")))
    little("close"); time.sleep(0.5)


def test_gone_space_asks_again(t, w):
    ask(w.url("lost"))
    for _ in ROWS: key(UP)
    st = key(DOWN)
    t.ok("the arrows mark Family", marked(st) == "Family", st.get("rows"))
    home = window_in(windows()["windows"], "Home").get("n")
    space("go", window=home, index=2); time.sleep(0.8)
    left = space("delete", window=home); time.sleep(1)
    t.ok("Family deleted", "Family" not in [s["name"] for s in left.get("spaces", [])], left.get("spaces"))
    before, memory = windows(), stored("links.ask.last")
    st = key(RETURN); time.sleep(0.5)
    t.ok("then Return opens nothing", opened_nothing(before, w.path("lost")), windows())
    t.ok("and remembers nothing", stored("links.ask.last") == memory, (memory, stored("links.ask.last")))
    t.ok("says the space is gone, and the link still waits",
         st.get("gone") is True and st.get("shown") and st.get("url") == w.url("lost"), st)
    t.ok("with the spaces left", [r["name"] for r in st.get("rows", [])] == [n for n in ROWS if n != "Family"],
         st.get("rows"))
    key(ESC)


def test_keep_with_spaces_off_leaves_it(t, w):
    link_in(w.url("off"), w.clients, True); time.sleep(1)
    c({"do": "ui", "spaces": False}); time.sleep(0.5)
    little("keep"); time.sleep(1)
    t.ok("spaces turned off, Open in Search leaves the small window in Clients as it is",
         w.url("off") in little()["littles"] and w.url("off") not in every_tab(windows()["windows"]),
         (little()["littles"], windows()["windows"]))
    t.ok("and asks nothing: Clients is still there", chooser().get("shown") is False, chooser())
    little("close"); time.sleep(0.5)


def test_space_then_digit_saves_rule_and_opens_tab(t, w):
    ask(w.url("always"))
    st = key(SPACE_BAR)
    t.ok("Space turns Always on", st.get("always") is True, st)
    st = key(TWO); time.sleep(1)
    ws = windows()
    t.ok("2 then saves 127.0.0.1 to Family in Send links to a space",
         stored("spaces.links.rules") == [{"site": "127.0.0.1", "space": w.family}], stored("spaces.links.rules"))
    t.ok("and opens a tab in Family, not a small window, though links open in those",
         st.get("shown") is False and w.url("always") in window_in(ws["windows"], "Family").get("tabs", [])
         and ws["littles"] == [], ws)
    t.ok("with Family's sign-ins", sent(w.path("always")) == "who=family", first)


def test_always_hidden_when_send_links_off(t, w):
    st = ask(w.url("hidden"))
    t.ok("Send links to a space off: no Always", st.get("shown") and st.get("alwaysShown") is False, st)
    st = key(SPACE_BAR)
    t.ok("and Space changes nothing", st.get("shown") and st.get("always") is False, st)
    key(ESC)


def test_digit_opens_tab_when_links_open_in_tabs(t, w):
    ask(w.url("tabbed"))
    st = key(TWO); time.sleep(1)
    ws = windows()
    t.ok("links opening in tabs, 2 opens a tab in Family, with its sign-ins",
         st.get("shown") is False and w.url("tabbed") in window_in(ws["windows"], "Family").get("tabs", [])
         and ws["littles"] == [] and sent(w.path("tabbed")) == "who=family", ws)
    t.ok("and saves no rule", stored("spaces.links.rules") is None, stored("spaces.links.rules"))


# Links from other apps, on the path macOS hands them over on (Links.take).
# A probe is hidden, as ⌘H leaves the app, so every link asked about keeps
# the windows away until a tab is chosen.


def test_rule_match_skips_chooser(t, w):
    link(w.ruled("ruled")); time.sleep(1)
    ws = windows()["windows"]
    t.ok("a link to localhost, which a rule sends to Family, opens there",
         w.ruled("ruled") in window_in(ws, "Family").get("tabs", []) and w.path("ruled") in hits, ws)
    t.ok("and nothing asks", chooser().get("shown") is False, chooser())


def test_no_rule_shows_chooser_and_loads_nothing(t, w):
    # Home on screen again, not Family, where the rule went: the choice has
    # to send the link there.
    space("go", index=3); time.sleep(0.8)
    before = windows()
    t.ok("Home on screen", [x["space"] for x in before["windows"]] == ["Home"], before)
    link(w.url("asked"), sender="Mail")
    st = chooser()
    t.ok("a link no rule sends: the panel asks, named for the app it came from",
         st.get("shown") and st.get("url") == w.url("asked") and st.get("title") == "Open a link from Mail", st)
    t.ok("nothing opens, and the page is never asked for", opened_nothing(before, w.path("asked")), (windows(), hits))
    t.ok("the windows kept away while it asks", away(windows()), windows())
    st = key(TWO); time.sleep(1)
    ws = windows()
    t.ok("2 opens it in a tab in Family, with Family's sign-ins from its first request",
         st.get("shown") is False and w.url("asked") in window_in(ws["windows"], "Family").get("tabs", [])
         and sent(w.path("asked")) == "who=family", (st, ws, first))
    t.ok("asked for once", hits.get(w.path("asked")) == 1, hits.get(w.path("asked")))
    t.ok("and the windows back", not ws["keptAway"] and not any(x["away"] for x in ws["windows"]), ws)


def test_two_links_ask_in_turn(t, w):
    link(w.url("first")); link(w.url("second"))
    st = chooser()
    t.ok("a second link while one waits: the first is asked about, the second waits behind it",
         st.get("url") == w.url("first") and st.get("queued") == 1, st)
    st = key(TWO); time.sleep(1)
    t.ok("after a choice, the second", st.get("url") == w.url("second") and st.get("queued") == 0, st)
    link(w.url("third"))
    st = chooser()
    t.ok("a third while the second waits: behind it", st.get("url") == w.url("second") and st.get("queued") == 1, st)
    st = key(ESC)
    t.ok("after Esc, the third", st.get("url") == w.url("third") and st.get("queued") == 0, st)
    st = key(ESC); time.sleep(0.5)
    t.ok("and after Esc again, none", st.get("shown") is False, st)
    t.ok("only the one chosen was asked for",
         w.path("first") in hits and w.path("second") not in hits and w.path("third") not in hits, hits)


def test_open_page_comes_forward_without_chooser(t, w):
    def active(): return next((x["url"] for x in c({"do": "tabs"})["tabs"] if x["active"]), "")
    c({"do": "open", "url": w.url("open")}); time.sleep(1.5)
    t.ok("the page opens behind", active() != w.url("open"), active())
    link(w.url("open")); time.sleep(0.5)
    t.ok("a link to it: its tab comes forward", active() == w.url("open"), active())
    t.ok("with no panel and no small window", chooser().get("shown") is False and little()["littles"] == [],
         (chooser(), little()["littles"]))
    link(w.url("nowhere-open"))
    st = chooser()
    t.ok("a page open nowhere: the panel asks", st.get("shown") and st.get("url") == w.url("nowhere-open"), st)
    key(ESC)


def test_off_by_default_opens_as_today(t, w):
    link(w.url("off")); time.sleep(1)
    t.ok("never turned on: a link opens in a small window, as before",
         little()["littles"] == [w.url("off")] and sent(w.path("off")) is not None, (little()["littles"], hits))
    t.ok("and nothing asks", chooser().get("shown") is False and stored("links.ask") is None,
         (chooser(), stored("links.ask")))
    c({"do": "history", "clear": "all"}); time.sleep(0.5)
    t.ok("clearing history writes no memory of where links went", stored("links.ask.last") is None,
         stored("links.ask.last"))


def test_one_space_opens_as_today(t):
    url = f"{sv.BASE}/one-space"
    link(url); time.sleep(1)
    t.ok("with one space in all: a link opens in its small window, unasked",
         little()["littles"] == [url] and chooser().get("shown") is False, (little()["littles"], chooser()))


MAILTO = "mailto:a@example.com?subject=Hi"


def mail(): return c({"do": "mail"})


def hosts():
    """The sites the page views in memory have loaded, in a tab or not."""
    return {urlsplit(u).hostname for u in c({"do": "alive"})["urls"]} - {None}


def composed():
    """The webmail's compose page the last email link became."""
    seen = mail()["seen"]
    return seen[-1][len("app: "):] if seen and seen[-1].startswith("app: ") else None


def test_mailto_asks_with_compose_page(t):
    before, loaded = windows(), hosts()
    link(MAILTO, sender="Mail"); time.sleep(1.5)
    compose = composed()
    st = chooser()
    t.ok("an email link: the panel asks about Gmail's compose page, from Mail",
         compose and compose.startswith("https://mail.google.com/") and st.get("url") == compose
         and st.get("title") == "Open a link from Mail", (compose, st))
    t.ok("nothing loads before the choice: no tab, no small window, no site loaded",
         every_tab(windows()["windows"]) == every_tab(before["windows"]) and little()["littles"] == []
         and hosts() == loaded, (windows(), hosts() - loaded))
    key(ONE); time.sleep(1.5)
    added = [u for u in every_tab(windows()["windows"]) if u not in every_tab(before["windows"])]
    t.ok("1 opens it, in a tab", chooser().get("shown") is False and len(added) == 1, (chooser(), added))


def test_mailto_opens_as_today(t):
    before, loaded = windows(), hosts()
    link(MAILTO); time.sleep(1.5)
    added = [u for u in every_tab(windows()["windows"]) if u not in every_tab(before["windows"])]
    t.ok("switched off, an email link opens Gmail's compose page in a tab, as before",
         (composed() or "").startswith("https://mail.google.com/") and len(added) == 1, (composed(), added))
    # The check above that nothing loaded, seeing the load here.
    t.ok("and a site loads at once", hosts() - loaded, (loaded, hosts()))
    t.ok("and nothing asks", chooser().get("shown") is False, chooser())


def test_cold_launch_waits_for_choice(t, w, choose, last):
    name = "chosen" if choose else "cancelled"
    url, path = w.url(name), w.path(name)
    sv.quit(); time.sleep(1)
    sv.launch(link=url); time.sleep(1)
    st, ws = chooser(), windows()
    t.ok("a link that launches the app: the panel asks", st.get("shown") and st.get("url") == url, st)
    t.ok("with every space, the one chosen last for the site marked",
         [r["name"] for r in st.get("rows", [])] == ROWS and marked(st) == last, st.get("rows"))
    t.ok("every window kept away and off screen",
         ws["windows"] and away(ws) and not any(x["shown"] for x in ws["windows"]), ws)
    t.ok("and nothing opened or loaded", url not in every_tab(ws["windows"]) and path not in hits, (ws, hits))
    if choose:
        st = key(TWO); time.sleep(1)
        ws = windows()
        t.ok("2 opens it in a tab in Family, with Family's sign-ins",
             st.get("shown") is False and url in window_in(ws["windows"], "Family").get("tabs", [])
             and sent(path) == "who=family", (st, ws, first))
        t.ok("and brings the windows back", not ws["keptAway"] and not any(x["away"] for x in ws["windows"]), ws)
    else:
        st = key(ESC); time.sleep(3)
        ws = windows()
        t.ok("Esc: no link waits, and none opened", st.get("shown") is False and url not in every_tab(ws["windows"])
             and path not in hits, (st, ws))
        t.ok("and the windows stay away, the app running with none", away(ws), ws)


def run(t, tag, one_window):
    print(f"— Profiles in one window {'on' if one_window else 'off'}")
    w = seed(t, tag, one_window)
    # In this order: Family before Work has a browser, the small window in
    # Clients then makes Work's out of sight, the tab after it brings that
    # out, and Clients goes last.
    test_link_in_small_window_same_profile_uses_chosen_space(t, w)
    test_link_in_small_window_uses_chosen_space(t, w)
    test_tab_after_small_window_is_on_screen(t, w)
    test_keep_keeps_chosen_space(t, w)
    test_link_in_tab_uses_chosen_space(t, w)
    test_window_a_page_opens_keeps_chosen_space(t, w)
    test_new_tabs_from_small_window_keep_chosen_space(t, w)
    test_keep_with_gone_space_asks_again(t, w)
    test_link_in_gone_space_opens_nothing(t, w)


def run_ruled(t):
    print("— A site a rule sends to Home, from a small window in Family")
    w = seed(t, "ruled", False, sends_links=True)
    home = next(s["id"] for s in space("list")["spaces"] if s["name"] == "Home")
    # Family and Home each signed in to localhost too; Home on screen after.
    space("go", index=2); time.sleep(0.8)
    open_tab(w.ruled("set?who=family"))
    space("go", index=3); time.sleep(0.8)
    open_tab(w.ruled("set?who=home"))
    # The rule, written as Settings writes it, read at the next launch.
    sv.quit(); time.sleep(1)
    subprocess.run(["defaults", "write", sv.SUITE, "spaces.links.rules", "-array",
                    f'{{ site = localhost; space = "{home}"; }}'], check=True)
    sv.launch(); time.sleep(1)
    test_ruled_site_from_small_window_opens_in_its_space(t, w)


def run_kept_away(t, tag, one_window):
    print(f"— Windows kept away, Profiles in one window {'on' if one_window else 'off'}")
    test_kept_away_windows_wait_for_the_choice(t, seed(t, tag, one_window, small_windows=True))


def run_other_profile(t, tag, one_window):
    print(f"— A new tab from a small window of Work, Profiles in one window {'on' if one_window else 'off'}")
    test_new_tab_from_other_profile_comes_into_sight(t, seed(t, tag, one_window))


def run_brought_forward(t):
    # With Profiles in one window off: on, Work's browser is tucked behind
    # Home's, which brings it in Home's place (OneWindow.swift).
    print("— Work's browser kept out of sight, brought forward by something else")
    test_brought_forward_comes_into_sight(t, seed(t, "forward", False))


def run_relaunch(t, tag):
    print("— A relaunch, then Profiles in one window turned on")
    w = seed(t, tag, False)
    test_relaunch_keeps_it_out_of_sight(t, w)
    test_one_window_turned_on_brings_it(t, w)


def run_chooser(t):
    print("— The chooser, links opening in small windows")
    w = seed(t, "chooser", False, small_windows=True, sends_links=True)
    # Each from no link waiting; Family is deleted near the end, and spaces
    # are turned off last.
    test_look_lists_rows_in_menu_order_with_digits(t, w)
    test_escape_opens_nothing(t, w)
    test_command_digit_does_nothing(t, w)
    test_held_digit_opens_nothing_held_arrow_walks(t, w)
    test_digit_opens_at_once(t, w)
    test_arrow_and_keypad_return_with_their_flags(t, w)
    test_return_opens_marked_last_choice(t, w)
    test_no_site_hides_always(t, w)
    test_gone_space_asks_again(t, w)
    test_keep_with_spaces_off_leaves_it(t, w)


def run_always(t):
    # Its own launch: it saves a rule for 127.0.0.1, which the others need unruled.
    print("— Always, with Send links to a space on")
    test_space_then_digit_saves_rule_and_opens_tab(t, seed(t, "always", False, small_windows=True, sends_links=True))


def run_no_always(t):
    print("— No Always, with Send links to a space off and links opening in tabs")
    w = seed(t, "no-always", False, small_windows=False, sends_links=False)
    test_always_hidden_when_send_links_off(t, w)
    test_digit_opens_tab_when_links_open_in_tabs(t, w)


def run_outside(t):
    print("— Links from other apps, Ask which space on, links opening in tabs")
    w = seed(t, "outside", False, sends_links=True, more={"links.ask": True})
    # The rule, written as Settings writes it, read at the next launch.
    sv.quit(); time.sleep(1)
    subprocess.run(["defaults", "write", sv.SUITE, "spaces.links.rules", "-array",
                    f'{{ site = localhost; space = "{w.family}"; }}'], check=True)
    sv.launch(); time.sleep(1)
    test_rule_match_skips_chooser(t, w)
    test_no_rule_shows_chooser_and_loads_nothing(t, w)
    test_two_links_ask_in_turn(t, w)


def run_open_page(t):
    print("— Ask which space on, with Go to the open page on")
    w = seed(t, "open-page", False, small_windows=True, more={"links.ask": True, "links.little.tabs": True})
    test_open_page_comes_forward_without_chooser(t, w)


def run_off(t):
    print("— Ask which space never turned on, links opening in small windows")
    test_off_by_default_opens_as_today(t, seed(t, "off", False, small_windows=True))


def run_one_space(t):
    print("— Ask which space on, with one space in all")
    sv.setup(**{"spaces": True, "links.little": True, "links.ask": True})
    sv.launch()
    test_one_space_opens_as_today(t)


def run_mailto(t):
    print("— Email links, with Gmail chosen and links opening in tabs")
    for asks, check in ((True, test_mailto_asks_with_compose_page), (False, test_mailto_opens_as_today)):
        sv.setup(**{"spaces": True, "links.little": False, "links.ask": asks})
        subprocess.run(["defaults", "write", sv.SUITE, "mail.webmail", "-string", "gmail"], check=True)
        sv.launch()
        # A second space, so there is a choice to ask about; back at the first.
        space("new", name="Family", fresh=True); time.sleep(0.8)
        space("go", index=1); time.sleep(0.8)
        check(t)


def run_cold(t):
    print("— A link that launches the app, Ask which space on")
    w = seed(t, "cold", False, more={"links.ask": True})
    # Clients chosen for 127.0.0.1 before the quit, which brings Work's
    # window out: two windows to keep away.
    ask(w.url("before")); key(FIVE); time.sleep(1)
    test_cold_launch_waits_for_choice(t, w, choose=True, last="Clients")
    test_cold_launch_waits_for_choice(t, w, choose=False, last="Family")


def main():
    t = sv.T()
    try:
        run(t, "apart", False)
        run(t, "merged", True)
        run_ruled(t)
        run_kept_away(t, "away-apart", False)
        run_kept_away(t, "away-merged", True)
        run_other_profile(t, "other-apart", False)
        run_other_profile(t, "other-merged", True)
        run_brought_forward(t)
        run_relaunch(t, "relaunched")
        run_chooser(t)
        run_always(t)
        run_no_always(t)
        run_outside(t)
        run_open_page(t)
        run_off(t)
        run_one_space(t)
        run_mailto(t)
        run_cold(t)
    except Exception as error:
        t.ok("the link chooser's probe ran to the end", False, repr(error))
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
