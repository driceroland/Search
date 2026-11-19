#!/usr/bin/env python3
"""Email links in a webmail (Webmail.swift), in a hidden probe.

Build first (`./build.sh debug`), then `python3 Tests/webmail.py`. It uses
the split suite's harness in a world of its own (webmail-tests): started
hidden, no window shown, everything removed afterwards.

A mailto: from another app is handed in where the system's open-URL handler
hands one (`windows link`, Links.arrived). Nothing here makes the probe the
Mac's email app or asks LaunchServices to: a test run opens no other app, it
says which it would (the probe's `mail`).
"""
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import urlsplit, parse_qs

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("webmail-tests")
t = sv.T()

LINK = "mailto:a@example.com,user+tag@example.com?cc=c@example.com&subject=Hi%20%26%20bye&body=line%201%0D%0Aline%202%20%C3%A9"
_served = sv.H.do_GET


def _get(self):
    """/mail: a page with the link on it, on the harness's own server."""
    if self.path != "/mail": return _served(self)
    body = ("<!doctype html><meta charset=utf-8><title>mail</title>"
            f"<a id=m href='{LINK}' style='display:block;width:300px;height:80px'>write</a>"
            f"<a id=b target=_blank href='{LINK}' style='display:block;width:300px;height:80px'>write apart</a>").encode()
    self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8")
    self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)


sv.H.do_GET = _get
PAGE = f"{sv.BASE}/mail"


def tabs(): return sv.cmd({"do": "tabs"})["tabs"]
def mail(**f): return sv.cmd({"do": "mail", **f})
def windows(**f): return sv.cmd({"do": "windows", **f})
def webmail(name): subprocess.run(["defaults", "write", sv.SUITE, "mail.webmail", "-string", name])


def gmail_ok(url):
    q = parse_qs(urlsplit(url).query)
    return (url.startswith("https://mail.google.com/mail/?view=cm&fs=1&")
            and q.get("to") == ["a@example.com,user+tag@example.com"] and q.get("cc") == ["c@example.com"]
            and q.get("su") == ["Hi & bye"] and q.get("body") == ["line 1\nline 2 é"])


def unregister():
    # Declaring mailto makes any copy of the app LaunchServices knows of a
    # candidate email app: the probe's build is forgotten again.
    subprocess.run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                    "-u", sv.APP], capture_output=True)


try:
    # From another app, with Gmail chosen and links in the window: compose
    # in a tab.
    sv.setup(**{"links.little": False}); webmail("gmail"); sv.launch()
    before = len(tabs())
    windows(action="link", url=LINK); time.sleep(1.5)
    seen = mail()["seen"]
    t.ok("a mailto from another app becomes Gmail's compose page", len(seen) == 1 and seen[0].startswith("app: ")
         and gmail_ok(seen[0][5:]), seen)
    t.ok("in a tab (the blank one, here)", len(tabs()) in (before, before + 1), tabs())
    front = next(x for x in tabs() if x["active"])
    t.ok("in front, Gmail's (or Google's sign-in on the way to it)",
         urlsplit(front["url"]).hostname in ("mail.google.com", "accounts.google.com"), front["url"])

    # Clicked in a private tab's page: compose in an ordinary tab, beside it.
    # The page clicked in is the tab you're on, as it is for a real click.
    page = sv.cmd({"do": "open", "url": PAGE, "private": True}); time.sleep(2)
    sv.cmd({"do": "select", "id": page["id"]})
    t.ok("the page is a private tab", page["shy"], page)
    count = len(tabs())
    sv.cmd({"do": "tap", "id": page["id"], "selector": "#m"}); time.sleep(1.5)
    seen = mail()["seen"]
    now = tabs()
    t.ok("a mailto clicked in a page opens compose", seen[-1].startswith("page: ") and gmail_ok(seen[-1][6:]), seen)
    t.ok("in a new tab", len(now) == count + 1, now)
    at = [x["id"] for x in now].index(page["id"])
    beside = now[at + 1] if at + 1 < len(now) else {}
    t.ok("next to the page", beside.get("active") and urlsplit(beside.get("url", "")).hostname in ("mail.google.com", "accounts.google.com"), now)
    t.ok("an ordinary tab, not a private one", beside.get("shy") is False, beside)
    t.ok("the page stays where it was", next(x for x in now if x["id"] == page["id"])["url"] == PAGE, now)

    # A link that asks for a new window: one tab, the compose page, and no
    # blank one left behind.
    sv.cmd({"do": "select", "id": page["id"]}); count = len(tabs())
    sv.cmd({"do": "tap", "id": page["id"], "selector": "#b"}); time.sleep(2)
    now = tabs()
    t.ok("target=_blank: one new tab", len(now) == count + 1, [(x["url"][:40], x["shy"]) for x in now])
    t.ok("and it is the compose page", mail()["seen"][-1].startswith("page: "), mail()["seen"])
    t.ok("no blank tab left", all(x["url"] for x in now), [(x["url"][:40], x["shy"]) for x in now])

    # Send Feedback: compose directly, the version in its subject.
    mail(action="feedback"); time.sleep(1)
    seen = mail()["seen"]
    q = parse_qs(urlsplit(seen[-1].split(": ", 1)[1]).query) if seen[-1].startswith("feedback: ") else {}
    t.ok("Send Feedback opens Gmail's compose page", q.get("to") == ["hello@officecommun.com"]
         and q.get("su", [""])[0].startswith("Search feedback"), seen[-1])
    sv.quit()

    # A small window for links from other apps: compose in one.
    sv.setup(**{"links.little": True}); webmail("outlook"); sv.launch()
    windows(action="link", url=LINK); time.sleep(1.5)
    little = sv.cmd({"do": "little", "what": "look"})["littles"]
    seen = mail()["seen"]
    t.ok("Outlook's compose page", seen[-1:] and seen[-1].startswith("app: https://outlook.live.com/mail/0/deeplink/compose?to=a%40example.com"), seen)
    t.ok("with small windows on, in a small window", len(little) == 1, little)
    sv.quit()

    # None: a mailto that comes anyway goes on to another app, never back
    # here; a clicked one still goes to the Mac's mail app as before.
    sv.setup(**{"links.little": False}); webmail("none"); sv.launch()
    before = len(tabs())
    windows(action="link", url=LINK); time.sleep(1)
    seen = mail()["seen"]
    t.ok("None: handed on to another app", len(seen) == 1 and seen[0].startswith("system: ") and "Search" not in seen[0], seen)
    t.ok("no tab for it", len(tabs()) == before, tabs())
    page = sv.cmd({"do": "open", "url": PAGE}); time.sleep(2)
    sv.cmd({"do": "tap", "id": page["id"], "selector": "#m"}); time.sleep(1)
    t.ok("None: a click in a page is handed off as before", sv.cmd({"do": "probe"})["handedOff"][-1:] == ["mailto: asked"],
         sv.cmd({"do": "probe"})["handedOff"])
    mail(action="feedback")
    t.ok("None: Send Feedback goes to the mail app", mail()["seen"][-1] == "feedback: system", mail()["seen"])
finally:
    t.done(); sv.finish(); unregister()
sys.exit(1 if t.failed else 0)
