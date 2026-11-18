#!/usr/bin/env python3
"""Coding agents in the Search you have open (AgentControl), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/agent_control.py`. The split
suite's harness starts the build hidden in a world of its own with
"Let coding agents use Search" on, and removes everything afterwards. The
agent's side is ./search-mcp, spoken to over stdio as Claude Code would.
The window's question is answered through the bench's `agents` verb, which
only a test run has.

Checked: nothing happens until the question is answered, and only one agent
at a time; the agent's own tab on a page served from 127.0.0.1, read with a
password's value kept in the page; typing checked; a real click and the page
it leads to; addresses Search won't go to and keys it won't press; a
picture with the password blacked out; your tabs unseen unless allowed,
read-only when allowed, a private one never; Stop dropping the connection;
Don't Allow, and no question again straight after.
"""

import base64
import json
import os
import socket
import stat
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("agent-control")
ROOT = Path(__file__).resolve().parents[1]
VERBOSE = "-v" in sys.argv
AGENT_SOCK = f"{sv.SUPPORT}/Agent/agent.sock"

FORM = """<!doctype html><title>form</title>
<h1>Sign in</h1>
<form action="/done" method="get">
  <label>Name <input name="name" id="name"></label>
  <label>Password <input type="password" name="pw" value="hunter2-secret"></label>
  <button id="go">Send</button>
</form>
<p><a href="file:///etc/hosts" id="file">A file</a></p>
"""


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/done":
            name = parse_qs(url.query).get("name", [""])[0]
            body = f"<!doctype html><title>done</title><p>Hello {name}</p>"
        elif url.path == "/perm":
            # What a page in an agent's tab is answered when it asks to see,
            # hear, locate or notify: each answer written into the page.
            body = """<!doctype html><title>perm</title><p id=out></p><script>
              var out = document.getElementById('out');
              function say(k, v) { out.textContent += k + '=' + v + ' '; }
              Notification.requestPermission().then(function (p) { say('notify', p); });
              navigator.mediaDevices.getUserMedia({ video: true, audio: true })
                .then(function () { say('camera', 'granted'); }, function (e) { say('camera', e.name); });
              navigator.geolocation.getCurrentPosition(function () { say('where', 'granted'); },
                function (e) { say('where', 'denied' + e.code); });
            </script>"""
        elif url.path == "/frames":
            body = """<!doctype html><title>frames</title>
              <label>Password <input type=password value="frame-secret"></label>
              <iframe srcdoc="<p>inside</p>" style="width:200px;height:80px"></iframe>
              <shut-thing style="display:block;width:100px;height:30px"></shut-thing>
              <script>customElements.define('shut-thing', class extends HTMLElement {
                constructor() { super(); this.attachShadow({ mode: 'closed' }).innerHTML = '<b>hidden</b>'; } });</script>"""
        else:
            body = FORM
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), Page)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"


class Client:
    """./search-mcp, as an agent runs it."""

    def __init__(self, name="claude-code"):
        self.p = subprocess.Popen(
            [str(ROOT / "search-mcp"), "--world", sv.W],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
        )
        self.n = 0
        init = self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                       "clientInfo": {"name": name}})
        assert init["serverInfo"]["name"] == "search", init

    def send(self, method, params=None):
        self.n += 1
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params or {}}) + "\n")
        self.p.stdin.flush()
        return self.n

    def answer(self, n):
        out = json.loads(self.p.stdout.readline())
        assert out["id"] == n, out
        return out["result"]

    def rpc(self, method, params=None):
        return self.answer(self.send(method, params))

    def tool(self, which, /, **args):
        out = self.rpc("tools/call", {"name": which, "arguments": args})
        return said(which, args, out)

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(5)
        except Exception:
            self.p.kill()


def said(which, args, out):
    if VERBOSE:
        print(f"  {which} {json.dumps(args)[:100]} → {json.dumps(out)[:260]}")
    content = out["content"]
    if len(content) == 1 and content[0]["type"] == "text":
        return json.loads(content[0]["text"]), bool(out.get("isError"))
    return content, bool(out.get("isError"))


def code(x):
    return x.get("error", {}).get("code") if isinstance(x, dict) else None


def node(read, role, name):
    return next((n for n in read["nodes"] if n["role"] == role and n["name"] == name), None)


def agents(action="state", **f):
    return sv.cmd({"do": "agents", "action": action, **f})


def until(check, within=10):
    end = time.time() + within
    while time.time() < end:
        if check():
            return True
        time.sleep(0.1)
    return False


def raw_connect():
    """A second program connecting while one is there: what it hears."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as c:
        c.settimeout(5)
        c.connect(AGENT_SOCK)
        c.sendall(b'{"do":"hello","client":"other"}\n')
        data = b""
        while b"\n" not in data:
            chunk = c.recv(4096)
            if not chunk:
                break
            data += chunk
    return json.loads(data.split(b"\n")[0] or b"{}")


t = sv.T()


def main():
    clients = []
    try:
        sv.setup(agents=True)
        # A notification grant you gave the test site before, which the
        # agent's tab never gets (M1).
        subprocess.run(["defaults", "write", sv.SUITE, f"capture.{BASE}|notifications", "-bool", "true"])
        sv.launch()
        t.ok("the socket is there with the setting on", until(lambda: os.path.exists(AGENT_SOCK)))
        mode = os.stat(AGENT_SOCK).st_mode
        t.ok("the socket is a socket, 0600", stat.S_ISSOCK(mode) and stat.S_IMODE(mode) == 0o600, oct(mode))
        room = os.lstat(os.path.dirname(AGENT_SOCK))
        t.ok("in a folder of its own, 0700", stat.S_ISDIR(room.st_mode) and stat.S_IMODE(room.st_mode) == 0o700, oct(room.st_mode))
        # A tab of yours, and a private one, before any agent.
        yours = sv.sp("open", url=f"{BASE}/yours")["resultID"]
        sv.cmd({"do": "open", "url": f"{BASE}/private-one", "private": True})
        time.sleep(1)

        # ---- the first agent: nothing until allowed
        a = Client("claude-code"); clients.append(a)
        n = a.send("tools/call", {"name": "open_tab", "arguments": {"url": f"{BASE}/form"}})
        t.ok("the question is up", until(lambda: agents().get("state") == "asking"), agents())
        st = agents()
        t.ok("it names the client", st.get("client") == "Claude Code", st)
        t.ok("and the program that asked", "python" in st.get("program", "").lower() or st.get("program"), st)
        time.sleep(1.5)
        t.ok("nothing opened while asking", st.get("own") == 0 and agents().get("own") == 0)
        tabs_before = {x["id"] for x in sv.cmd({"do": "tabs"})["tabs"]}
        t.ok("no agent tab yet", not any(x.get("bench") and x["id"] not in (yours,) for x in sv.cmd({"do": "tabs"})["tabs"]
                                        if x["url"].endswith("/form")), tabs_before)
        other = raw_connect()
        t.ok("a second agent is turned away", code(other) == "busy", other)
        agents("allow")
        opened, err = said("open_tab", {}, a.answer(n))
        t.ok("allowed: its tab opens", not err and opened.get("page") == "p1" and opened["url"].endswith("/form"), opened)
        t.ok("allowed, without your tabs", agents().get("state") == "allowed" and agents().get("seesTabs") is False)

        # ---- reading, with the password kept in the page
        read, err = a.tool("read_page", page="p1")
        text = json.dumps(read)
        pw = node(read, "textbox", "Password") if not err else None
        t.ok("read_page gives controls with handles", not err and node(read, "textbox", "Name", ) and pw, read)
        t.ok("the password's value never leaves the page", "hunter2" not in text and pw and pw.get("redacted"), pw)
        name = node(read, "textbox", "Name")
        typed, err = a.tool("type", element=name["element"], text="Ada")
        t.ok("typing is checked", not err and typed.get("verified") is True, typed)
        typed, err = a.tool("type", element=pw["element"], text="new-secret-9", keys=True)
        t.ok("typing into the password, real keys, checked", not err and typed.get("verified") is True, typed)
        t.ok("and never says what it held", "holds" not in typed and "want" not in typed, typed)
        again, _ = a.tool("read_page", page="p1")
        t.ok("what was typed in the password stays in the page", "new-secret-9" not in json.dumps(again), again)

        # ---- a picture, blacked out where it must be
        shot, err = a.tool("screenshot", page="p1")
        image = next((c for c in shot if c["type"] == "image"), None) if not err else None
        about = json.loads(next((c["text"] for c in shot if c["type"] == "text"), "{}")) if not err else {}
        t.ok("a picture of its own tab", image and base64.b64decode(image["data"])[:4] == b"\x89PNG", shot if err else about)
        t.ok("with the password blacked out", about.get("blackedOut", 0) >= 1, about)

        # ---- refusals, decided in Search
        for bad in ("file:///etc/hosts", "search://settings", "search://passwords", "javascript:alert(1)"):
            x, err = a.tool("navigate", page="p1", url=bad)
            t.ok(f"won't go to {bad}", err and code(x) == "refused_address", x)
        x, err = a.tool("press", page="p1", key="cmd+a")
        t.ok("no ⌘ keys", err and code(x) == "bad_key", x)
        for keys in ("ctrl+k", "ctrl+y"):
            x, err = a.tool("press", page="p1", key=keys)
            t.ok(f"H2: no {keys}", err and code(x) == "bad_key", x)
        x, err = a.tool("press", page="p1", key="Tab")
        t.ok("a named key is pressed", not err, x)
        for sel in ("input[value='hunter2-secret']", '[va\\lue^="h"]', '[v\\61lue^="h"]', "input:placeholder-shown"):
            x, err = a.tool("wait_for", page="p1", selector=sel, timeout=1)
            t.ok(f"H1: no selector {sel}", err and code(x) == "bad_condition", x)
        link = node(again, "link", "A file")
        x, err = a.tool("click", element=link["element"]) if link else ({}, True)
        t.ok("a link to a file goes nowhere", not err and not x.get("navigated") and x["url"].endswith("/form"), x)
        x, err = a.tool("wait_for", page="p9")
        t.ok("a page it doesn't have", err and code(x) == "stale_page", x)

        # ---- a real click and where it leads
        again, _ = a.tool("read_page", page="p1")
        x, err = a.tool("click", element=node(again, "button", "Send")["element"])
        t.ok("a real click submits the form", not err and x.get("navigated") is True, x)
        t.ok("L3: the address it is given keeps the password out", "new-secret-9" not in json.dumps(x) and "pw=redacted" in x.get("url", ""), x)
        time.sleep(1)
        t.ok("L7: no offer to save the password it signed in with", sv.cmd({"do": "probe"}).get("offering") is False)
        x, err = a.tool("wait_for", page="p1", url="pw=new", timeout=1)
        t.ok("L3: the address's secret can't be waited on", err and code(x) == "timeout", x)
        x, err = a.tool("wait_for", page="p1", text="Hello Ada")
        t.ok("wait_for the page it led to", not err and x.get("met") is True, x)

        # ---- M1: no camera, microphone, location or notifications
        x, err = a.tool("open_tab", url=f"{BASE}/perm")
        perm = x.get("page")
        x, err = a.tool("wait_for", page=perm, text="notify=", timeout=8)
        x, err = a.tool("wait_for", page=perm, text="camera=", timeout=8)
        said_, _ = a.tool("read_page", page=perm)
        words = said_.get("text", "")
        t.ok("M1: notifications denied, though the site was allowed", "notify=denied" in words, words)
        t.ok("M1: the camera refused", "camera=NotAllowedError" in words, words)
        t.ok("M1: the location never given", "where=granted" not in words, words)
        st = sv.cmd({"do": "probe"})
        t.ok("M1: no question raised for it", st.get("asking", "") == "", st.get("asking"))

        # ---- M2: frames and closed roots blacked out
        x, err = a.tool("open_tab", url=f"{BASE}/frames")
        shot, err = a.tool("screenshot", page=x.get("page"))
        about = json.loads(next((c["text"] for c in shot if c["type"] == "text"), "{}")) if not err else {}
        t.ok("M2: the password, the frame and the closed root blacked out", about.get("blackedOut") == 3, about)
        a.tool("close_tab", page=x.get("page"))
        a.tool("close_tab", page=perm)

        # ---- L6: the bench never reaches an agent's tab
        agent_tab = next(x["id"] for x in sv.cmd({"do": "tabs"})["tabs"] if x["url"].startswith(BASE + "/done"))
        sv.cmd({"do": "close", "id": "all"})
        t.ok("L6: the bench's close all leaves it", any(x["id"] == agent_tab for x in sv.cmd({"do": "tabs"})["tabs"]))
        try:
            sv.cmd({"do": "eval", "id": agent_tab, "js": "1"})
            t.ok("L6: the bench can't run a script in it", False)
        except RuntimeError as e:
            t.ok("L6: the bench can't run a script in it", "no tab" in str(e), str(e))

        # ---- only its own tabs
        listed, err = a.tool("list_tabs")
        pages = listed.get("tabs", []) if not err else []
        t.ok("list_tabs: only its own", pages and all(p["mine"] for p in pages) and len(pages) == 1, listed)
        mine = [x for x in sv.cmd({"do": "tabs"})["tabs"] if x["url"].startswith(BASE + "/done")]
        t.ok("its tab is a bench tab, never selected", mine and mine[0]["bench"] and not mine[0]["active"], mine)

        # ---- Stop
        agents("stop")
        t.ok("Stop: disconnected in Search", until(lambda: agents().get("connected") is False), agents())
        x, err = a.tool("list_tabs")
        t.ok("Stop: the agent hears it", err and code(x) == "stopped", x)
        x, err = a.tool("list_tabs")
        t.ok("and isn't asked about again straight away", err and code(x) == "not_now", x)
        a.close()
        t.ok("its tab stays for you to look at",
             any(x["url"].startswith(BASE + "/done") for x in sv.cmd({"do": "tabs"})["tabs"]))

        # ---- a second agent, allowed to see your tabs
        time.sleep(11)
        b = Client("codex"); clients.append(b)
        n = b.send("tools/call", {"name": "list_tabs", "arguments": {}})
        t.ok("asked again", until(lambda: agents().get("state") == "asking"), agents())
        time.sleep(0.7)
        agents("press")
        t.ok("M4: Allow pressed with no click behind it is ignored", agents().get("state") == "asking", agents())
        agents("allow", tabs=True)
        listed, err = said("list_tabs", {}, b.answer(n))
        urls = [p["url"] for p in listed.get("tabs", [])] if not err else []
        t.ok("with your tabs: yours listed", any(u.endswith("/yours") for u in urls), listed)
        t.ok("never a private one", not any("private-one" in u for u in urls), urls)
        theirs = next((p for p in listed.get("tabs", []) if p["url"].endswith("/yours")), None)
        if theirs:
            read, err = b.tool("read_page", page=theirs["page"])
            t.ok("your tab can be read", not err and read.get("title") == "form", read)
            t.ok("but gives no handles to touch it by", not err and all("element" not in nd for nd in read["nodes"]), read)
            x, err = b.tool("navigate", page=theirs["page"], url=f"{BASE}/elsewhere")
            t.ok("and is never used", err and code(x) == "not_yours", x)
            x, err = b.tool("screenshot", page=theirs["page"])
            t.ok("nor pictured", err and code(x) == "not_yours", x)
            x, err = b.tool("wait_for", page=theirs["page"], text="Sign in", timeout=1)
            t.ok("H1: on your tab, nothing in the page is waited on", err and code(x) == "bad_condition", x)
            x, err = b.tool("wait_for", page=theirs["page"], url="/yours", title="form", timeout=2)
            t.ok("H1: its address and title are", not err and x.get("met") is True, x)
        x, err = b.tool("disconnect")
        t.ok("disconnect lets go", not err and until(lambda: agents().get("connected") is False), x)
        b.close()

        # ---- Don't Allow
        c = Client("someone"); clients.append(c)
        n = c.send("tools/call", {"name": "open_tab", "arguments": {"url": f"{BASE}/form"}})
        t.ok("asked a third time", until(lambda: agents().get("state") == "asking"), agents())
        agents("deny")
        x, err = said("open_tab", {}, c.answer(n))
        t.ok("Don't Allow: refused", err and code(x) == "not_allowed", x)
        t.ok("and nothing opened", not any(t_["url"].endswith("/form") and t_["bench"] and not t_["url"].startswith(BASE + "/done")
                                           and t_["id"] not in tabs_before for t_ in sv.cmd({"do": "tabs"})["tabs"]))
        x, err = c.tool("list_tabs")
        t.ok("no new question straight after", err and code(x) == "not_now", x)

        # ---- L5: a question walked away from isn't asked again straight away
        time.sleep(11)
        d = Client("leaver"); clients.append(d)
        d.send("tools/call", {"name": "list_tabs", "arguments": {}})
        t.ok("L5: asked", until(lambda: agents().get("state") == "asking"), agents())
        d.close()
        t.ok("L5: gone with its client", until(lambda: agents().get("connected") is False), agents())
        other = raw_connect()
        t.ok("L5: and no new question straight after", code(other) == "not_now", other)

        # ---- L1: nothing it asked for runs after Stop
        time.sleep(11)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as c:
            c.settimeout(30)
            c.connect(AGENT_SOCK)
            c.sendall(b'{"do":"hello","client":"burst","n":0}\n')
            until(lambda: agents().get("state") == "asking")
            agents("allow")
            reader = c.makefile("rb")
            json.loads(reader.readline())
            c.sendall(b"".join(json.dumps({"do": "open", "url": f"{BASE}/burst?{i}", "n": i + 1}).encode() + b"\n"
                               for i in range(20)))
            for _ in range(3):
                json.loads(reader.readline())
            agents("stop")
            burst = lambda: sum(1 for x in sv.cmd({"do": "tabs"})["tabs"] if "/burst" in x["url"])
            at_stop = burst()
            time.sleep(5)
            t.ok("L1: what was queued didn't run after Stop", burst() == at_stop and at_stop < 20, (at_stop, burst()))

        # ---- L5: its window closing ends it
        time.sleep(11)
        sv.cmd({"do": "windows", "action": "new"})
        time.sleep(1)
        e = Client("window"); clients.append(e)
        e.send("tools/call", {"name": "list_tabs", "arguments": {}})
        t.ok("L5: asked in the first window", until(lambda: agents().get("state") == "asking"), agents())
        sv.cmd({"do": "windows", "action": "close", "n": 1})
        t.ok("L5: the window closed, the question is gone", until(lambda: agents().get("connected") is False), agents())
        e.close()

        # ---- L4: search-mcp won't speak to a socket that isn't Search's
        fake_world = f"agent-fake-{os.getpid()}"
        fake = f"{os.path.expanduser('~')}/Library/Application Support/Search ({fake_world})"
        try:
            os.makedirs(f"{fake}/Agent", mode=0o700)
            open(f"{fake}/Agent/agent.sock", "w").close()
            p = subprocess.Popen([str(ROOT / "search-mcp"), "--world", fake_world], stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            lines = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"clientInfo": {"name": "x"}}},
                     {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "list_tabs", "arguments": {}}}]
            out, _ = p.communicate("".join(json.dumps(m) + "\n" for m in lines), timeout=20)
            said_ = json.loads(json.loads(out.splitlines()[1])["result"]["content"][0]["text"])
            t.ok("L4: a file that isn't a socket is refused", code(said_) == "not_search", said_)
        finally:
            subprocess.run(["rm", "-rf", fake])

        # ---- the setting off: the socket goes
        agents("off")
        t.ok("turned off: the socket goes", until(lambda: not os.path.exists(AGENT_SOCK)))
    finally:
        for c in clients:
            c.close()
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
