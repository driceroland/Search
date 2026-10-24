#!/usr/bin/env python3
"""The accounts under a sign-in box, with Split View on, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/account_list_split.py`. With
Split View on, the list under a sign-in box was up — `accounts` said so — but
drawn under WebKit's page, so nobody saw it and a click there went to the
page. What a press lands on is asked of the window itself (`hit`): on the
list, the list's host; on the box, and off the list, the page. A local page
on 127.0.0.1:8832 has a name box and a password box, the name box focused
by the page as Roundcube's is; then a centred sign-in laid out as Urssaf's,
with Split View's switch on and no pair, the page a card beside the column:
the card as drawn hangs under the box at the top, scrolled and zoomed, and a
press on a row fills the form. What it saves is this world's own and is
forgotten at the end; no window is shown.
"""
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("account-split")

PORT = 8832
USER = "someone"

LOGIN = """<!doctype html><title>Webmail :: Welcome</title>
<form method="post" action="/" style="margin:120px 60px">
<input name="_user" id="u" type="text" style="width:270px;height:40px">
<input name="_pass" id="p" type="password" autocomplete="off" style="width:270px;height:40px">
<button type="submit">Login</button></form>
<script>document.addEventListener('DOMContentLoaded', function () { document.getElementById('u').focus(); });</script>"""


# Laid out as Urssaf's "Mon compte" is: a centred column, the boxes half way
# down the window, and more page under them to scroll.
CENTRED = """<!doctype html><title>Mon compte</title>
<body style="margin:0"><main style="max-width:420px;margin:0 auto;padding-top:42vh;height:2400px">
<form method="post" action="/">
<label>Email<input name="email" id="u" type="email" autocomplete="username" style="display:block;width:100%;height:44px"></label>
<label>Mot de passe<input name="password" id="p" type="password" autocomplete="current-password" style="display:block;width:100%;height:44px"></label>
<button type="submit">Se connecter</button></form></main></body>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = (LOGIN if self.path == "/" else CENTRED if self.path == "/centred"
                else "<!doctype html><title>Inbox</title><h1>Inbox</h1>").encode()
        self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def do_POST(self):
        # Signed in: the mailbox, a new document with no sign-in on it.
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self.send_response(302); self.send_header("Location", "/mail")
        self.send_header("Content-Length", "0"); self.end_headers()

    def log_message(self, *a): pass


def acc(**f): return sv.cmd({"do": "accounts", **f})
def hit(x, y): return sv.cmd({"do": "hit", "x": x, "y": y}).get("view", "")


def under_box(t, name, r, page):
    """The card as drawn hangs under the box it was asked for — left edges
    lined up, 6 points below — not wherever its page-sized host would centre
    it. Returns the card, in the window from its top-left."""
    card, spot = r.get("card"), r.get("spot")
    if not (r.get("shown") and card and spot and page):
        t.ok(f"{name}: the list is up, drawn on the stage", False, r)
        return None
    want = (page[0] + spot[0], page[1] + spot[1] + spot[3] + 6)
    t.ok(f"{name}: the card hangs under the box",
         abs(card[0] - want[0]) <= 2 and abs(card[1] - want[1]) <= 2, {"card": card, "want": want, "spot": spot, "page": page})
    return card


def centred(t, base):
    """Split View's switch on, no pair, the page as a card beside the column:
    the list under the password box of a centred sign-in, at the top, scrolled
    and zoomed, and a press on its row signs in."""
    tab = sv.sp("open", url=f"{base}/centred")["resultID"]
    sv.sp("select", id=tab); time.sleep(1.5)
    st = sv.cmd({"do": "probe"})
    page = st.get("activePageFrame")
    t.ok("centred: the page is a card beside the column", bool(page) and page[0] > 20, page)

    def focus(scroll=0):
        sv.ev(tab, """window.scrollTo(0, %d); var set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
          var u = document.getElementById('u'), p = document.getElementById('p');
          p.blur(); set.call(p, ''); set.call(u, %r); u.dispatchEvent(new Event('input', {bubbles: true})); true""" % (scroll, USER))
        # Out of the box long enough for the caret's leaving to count.
        time.sleep(0.5)
        sv.ev(tab, "document.getElementById('p').focus(); true")
        time.sleep(1.2)
        return acc()

    r = focus()
    card = under_box(t, "centred, at the top", r, page)
    if card:
        on = hit(card[0] + 40, card[1] + 18)
        t.ok("centred: a press on the card lands on the list", "AccountHost" in on, on)
        off = hit(card[0] + card[2] + 200, card[1] + card[3] + 100)
        t.ok("centred: below and right of the card is the page's", "AccountHost" not in off and off != "", off)

    r = focus(scroll=180)
    under_box(t, "centred, scrolled", r, page)

    sv.cmd({"do": "magnify", "id": tab, "zoom": 1.25}); time.sleep(0.8)
    r = focus(scroll=180)
    t.ok("centred, zoomed 125%: the box grew with the page", bool(r.get("spot")) and r["spot"][2] > 420, r.get("spot"))
    under_box(t, "centred, zoomed 125%", r, page)
    sv.cmd({"do": "magnify", "id": tab, "zoom": 1.0}); time.sleep(0.8)

    r = focus()
    card = under_box(t, "centred, back at the top", r, page)
    if card:
        # A hidden probe's SwiftUI button never fires (no key window), so the
        # press is checked for where it goes and what it leaves the keys
        # with; the pick itself through the list's own call.
        pressed = acc(press=[card[0] + 60, card[1] + 18])
        t.ok("centred: a press on a row reaches the list and leaves the keys in the page",
             pressed.get("pressed") == "AccountHost" and pressed.get("responder") == "PageView", pressed)
        r = focus()
        time.sleep(0.6)  # a list younger than half a second takes no pick
        if r.get("shown"):
            acc(pick=0); time.sleep(1.2)
        after = acc()
        filled = sv.ev(tab, "[document.getElementById('u').value, document.getElementById('p').value]")
        t.ok("centred: a pick fills the form and the list goes", after.get("shown") is False and filled == [USER, "pw-42"],
             {"shown": r.get("shown"), "after": after.get("shown"), "filled": filled})

    # Two pages up, the sign-in on the right: the card hangs from the box in
    # that page, not from the stage's corner.
    other = sv.sp("open", url=f"{base}/inbox")["resultID"]; time.sleep(0.7)
    sv.sp("select", id=other); sv.sp("pair", id=tab, **{"with": other}, side="right"); sv.sp("focus", id=tab)
    time.sleep(1.0)
    panes = {f["id"]: f for f in sv.sp("state")["paneFrames"]}
    right = panes.get(tab)
    t.ok("paired: the sign-in is the right page", bool(right) and right["x"] > 400, panes)
    if right:
        r = focus()
        under_box(t, "paired, on the right", r, [right["x"], right["y"]])
    sv.sp("close", id=other)
    sv.sp("close", id=tab)


def main():
    t = sv.T()
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{PORT}"
    try:
        sv.setup(splitView=True, sidebar=True, **{"layout.cards": True}); sv.launch()
        acc(forget=True)

        # Saved once, by hand.
        a = sv.sp("open", url=f"{base}/")["resultID"]
        sv.sp("select", id=a); time.sleep(1.5)
        sv.ev(a, """var set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
          var u = document.getElementById('u'), p = document.getElementById('p');
          set.call(u, %r); u.dispatchEvent(new Event('input', {bubbles: true}));
          p.focus(); set.call(p, 'pw-42'); p.dispatchEvent(new Event('input', {bubbles: true}));
          document.forms[0].requestSubmit(); true""" % USER)
        time.sleep(2)
        r = acc(keep=True)
        t.ok("kept in this world's keychain", r.get("kept") == 1, r)
        sv.sp("close", id=a)

        b = sv.sp("open", url=f"{base}/")["resultID"]
        sv.sp("select", id=b); time.sleep(1.5)
        r = acc()
        t.ok("Split View on: the list is up for the focused box", r.get("shown") is True, r)
        page = sv.cmd({"do": "probe"}).get("activePageFrame")
        t.ok("the page's place in the window is known", bool(page), page)
        if r.get("shown") and page:
            x, y, w, h = r["spot"]
            px, py = page[0], page[1]
            on_list = hit(px + x + 60, py + y + h + 6 + 18)
            t.ok("a press on the list lands on the list, not the page", "AccountHost" in on_list, on_list)
            on_box = hit(px + x + w / 2, py + y + h / 2)
            t.ok("a press on the box is still the page's", "AccountHost" not in on_box and on_box != "", on_box)
            off = hit(px + x + w + 300, py + y + h + 200)
            t.ok("a press off the list is still the page's", "AccountHost" not in off and off != "", off)
        sv.sp("close", id=b)

        centred(t, base)
    finally:
        try:
            r = acc(forget=True)
            t.ok("this world's logins forgotten", r.get("kept") == 0, r)
        except Exception as e:
            t.ok("this world's logins forgotten", False, e)
        srv.shutdown(); srv.server_close()
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
