#!/usr/bin/env python3
"""X's sign-in page, live, in a hidden probe: what Search could break before
anyone signs in.

Build first (`./build.sh debug`), then `python3 Tests/x_login.py`. Needs the
network; skips when x.com doesn't load. Nothing is typed into X's fields and
nothing is submitted: the page is read, and its Continue with Google and
Continue with Apple buttons are pressed (real clicks, the bench's tap). No
window is made or shown, and no account is used.

It checks that the whole form is drawn (the name field, Google's and Apple's
buttons), that X's own requests all come back, that Shield blocks none of the
hosts the sign-in uses, that Google's window keeps its opener (as a tab, and
as a small window with Settings › Tabs › Pop-ups in small windows), and that
Apple's button raises the system's Sign in with Apple sheet, as in a bare
WKWebView and in Safari.
"""
import json
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("x-login")
URL = "https://x.com/i/flow/login"

# X's own requests, recorded from the page's world: put in as early as the
# bench can reach a new document, and again until it stays.
HOOK = r"""(function () { if (window.__xl) return 'had';
  window.__xl = {calls: [], errors: []};
  addEventListener('error', function (e) { window.__xl.errors.push(String(e.message)); }, true);
  var f = window.fetch; window.fetch = function (input) { var u = String(typeof input === 'string' ? input : input && input.url);
    var p = f.apply(this, arguments); p.then(function (r) { window.__xl.calls.push([u.slice(0, 120), r.status]); },
      function (e) { window.__xl.calls.push([u.slice(0, 120), 'failed: ' + e]); }); return p; };
  return 'hooked'; })()"""

FORM = r"""JSON.stringify({
  url: location.href,
  name: !!document.querySelector('input[autocomplete~="username"], input[name="text"], input[name="username_or_email"]'),
  google: !!document.querySelector('iframe[src*="accounts.google.com/gsi/button"]'),
  apple: /Continue with Apple|Sign in with Apple/i.test(document.body ? document.body.innerText : ''),
  hosts: Array.from(new Set(performance.getEntriesByType('resource').map(function (r) { return new URL(r.name).host; }))),
  xl: window.__xl || null })"""

# The hosts X's sign-in reaches, its challenges and the two sign-in buttons'
# included, as in the report of 18 Nov 2026.
SIGN_IN_HOSTS = ["x.com", "api.x.com", "jf.x.com", "abs.twimg.com", "pbs.twimg.com", "twitter.com",
                 "client-api.arkoselabs.com", "x-api.arkoselabs.com", "challenges.cloudflare.com",
                 "accounts.google.com", "appleid.apple.com", "appleid.cdn-apple.com"]


def shield_domains():
    src = (sv.ROOT / "Sources/Search/Shield.swift").read_text()
    start = src.index("private static let unwanted = [")
    return re.findall(r'"([^"]+)"', src[start:src.index("]", start)])


def load():
    tab = sv.sp("open", url=URL)["resultID"]
    sv.sp("select", id=tab)
    for _ in range(120):
        try: sv.ev(tab, HOOK)
        except Exception: pass
        time.sleep(0.05)
    try: sv.cmd({"do": "wait", "id": tab, "seconds": 25})
    except Exception: pass
    for _ in range(30):
        form = json.loads(sv.ev(tab, FORM))
        if form["name"] and form["google"] and form["apple"]: break
        time.sleep(1)
    return tab, form


def tabs(window=1): return {x["id"]: x["url"] for x in sv.cmd({"do": "tabs", "window": window})["tabs"]}


def google(t, tab, label, windows):
    before = tabs()
    sv.cmd({"do": "tap", "id": tab, "selector": 'iframe[src*="gsi/button"]'}); time.sleep(6)
    if windows:
        made = len(sv.cmd({"do": "windows"})["windows"]) > 1
        t.ok(f"{label}: Continue with Google opens a small window", made)
        if not made: return
        signin = [x["id"] for x in sv.cmd({"do": "tabs", "window": 2})["tabs"]]
        opener = sv.cmd({"do": "eval", "id": signin[0], "js": "!!window.opener && location.host", "window": 2}).get("value")
        sv.cmd({"do": "windows", "action": "close", "n": 2})
    else:
        new = [k for k, v in tabs().items() if k not in before and "accounts.google.com" in v]
        t.ok(f"{label}: Continue with Google opens Google's sign-in", len(new) == 1, tabs())
        if not new: return
        opener = sv.ev(new[0], "!!window.opener && location.host")
        sv.sp("select", id=tab)
    t.ok(f"{label}: …which keeps X's page as its opener, to hand the sign-in back", opener == "accounts.google.com", opener)
    t.ok(f"{label}: …and nothing was refused as a pop-up", not sv.cmd({"do": "popups", "id": tab})["blocked"])


def main():
    t = sv.T()
    try:
        sv.setup(); sv.launch()
        tab, form = load()
        if not form["name"] and not form["google"]:
            print(f"  skip  x.com didn't load: {form['url']}"); return
        t.ok("the name field is drawn", form["name"], form)
        t.ok("Continue with Google is drawn (Google's frame)", form["google"], form)
        t.ok("Continue with Apple is drawn", form["apple"], form)
        calls = (form["xl"] or {}).get("calls", [])
        t.ok("X's own requests all come back", calls and all(c[1] == 200 for c in calls), calls)
        unwanted = shield_domains()
        hit = [h for h in set(SIGN_IN_HOSTS + form["hosts"])
               if any(h == d or h.endswith("." + d) for d in unwanted)]
        t.ok("Shield blocks none of the hosts the sign-in uses", not hit, hit)
        google(t, tab, "in a tab", windows=False)
        # Apple's button: WebKit hands the request to macOS (AppSSO), whose
        # sheet asks, as in Safari. On a hidden window it stays unseen.
        sv.cmd({"do": "tap", "id": tab, "selector": "text=Continue with Apple"}); time.sleep(4)
        p = sv.cmd({"do": "probe"})
        t.ok("Continue with Apple raises the system's Sign in with Apple sheet", p.get("sheet") is True, p.get("windows"))
        t.ok("…on no window anyone can see", not any(w.get("visible") for w in p.get("windows", [])), p.get("windows"))
    finally:
        sv.finish()
    try:
        sv.setup(**{"tabs.popupWindows": True}); sv.launch()
        tab, form = load()
        if form["google"]: google(t, tab, "small windows", windows=True)
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
