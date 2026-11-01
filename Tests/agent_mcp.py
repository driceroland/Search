#!/usr/bin/env python3
"""Claude's pages through shy-mcp (Agent.swift), in a hidden probe.

Build first (`./build.sh debug`), then `python3 Tests/agent_mcp.py`. Speaks
MCP to build/Shy.app/Contents/MacOS/shy-mcp over its standard input
and output, pointed at the test world's agent.sock, against pages served
here. Checks what Claude can do — open, read, picture, click, type, close —
and what a page can't: a file on this Mac, Shy's own pages, a window of
its own, a download, and the tabs that are yours.
"""
import base64
import json
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("agent-mcp")
HELPER = str(Path(sv.APP) / "Contents" / "MacOS" / "shy-mcp")
seen = []


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        seen.append("POST " + self.path)
        body = b"<!doctype html><title>Sent</title>SENT"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        seen.append(self.path)
        cookie = None
        if self.path == "/login":
            body, kind, cookie = b"<!doctype html><title>Signed in</title>SIGNED IN", "text/html", "sid=secret; Path=/"
        elif self.path == "/me":
            body = b"""<!doctype html><title>Me</title><p id=c></p>
<form method=post action=/send><button id=send>Send</button></form>
<script>document.getElementById('c').textContent = 'cookie:' + document.cookie</script>"""
            kind = "text/html"
        elif self.path == "/pointer":
            body = b"""<!doctype html><title>Pointer</title><style>body{margin:0;height:5000px}
#b{position:absolute;left:100px;top:100px;width:200px;height:60px}
#c{position:absolute;left:400px;top:100px;width:200px;height:60px}
#i{position:absolute;left:100px;top:300px;width:300px;height:40px}</style>
<p id=out>untouched</p><p id=pos>top</p>
<button id=b onclick="document.getElementById('out').textContent = 'clicked ' + (event.isTrusted ? 'trusted' : 'scripted')">Press</button>
<button id=c onclick="navigator.clipboard.writeText('stolen').catch(()=>{}); document.execCommand('copy')">Copy</button>
<input id=i onkeydown="if (event.key === 'Enter') document.getElementById('out').textContent = 'typed ' + this.value + ' enter'">
<script>addEventListener('scroll', () => document.getElementById('pos').textContent = 'scrolled ' + Math.round(scrollY));
document.addEventListener('copy', e => { e.clipboardData.setData('text/plain', 'stolen'); e.preventDefault(); });</script>"""
            kind = "text/html"
        elif self.path == "/form":
            body = b"""<!doctype html><title>Form</title>
<p id=out>untouched</p>
<input id=name oninput="document.getElementById('out').textContent = 'typed ' + this.value">
<button onclick="document.getElementById('out').textContent = 'clicked'">Press me</button>
<a id=away href="/second">Second page</a>
<a id=blank target=_blank href="/second">Elsewhere</a>
<button id=pop onclick="window.open('/second', 'x', 'width=300,height=300')">Pop</button>
<a id=file href="file:///etc/hosts">A file</a>
<a id=get href="/download">Download</a>"""
            kind = "text/html"
        elif self.path == "/store":
            # Signed in the way many web apps are: a token in page storage,
            # no cookie at all.
            body = b"""<!doctype html><title>Store</title>
<script>localStorage.setItem('token', 'tok-123'); sessionStorage.setItem('tab', 'ses-456')</script>STORED"""
            kind = "text/html"
        elif self.path == "/app":
            body = b"""<!doctype html><title>App</title><p id=s></p>
<button id=back onclick="history.back()">Back</button>
<script>document.getElementById('s').textContent = 'local:' + localStorage.getItem('token') + ' session:' + sessionStorage.getItem('tab')</script>"""
            kind = "text/html"
        elif self.path == "/second":
            body, kind = b"<!doctype html><title>Second</title>SECOND PAGE", "text/html"
        elif self.path == "/download":
            body, kind = b"\x00\x01binary", "application/octet-stream"
        else:
            body, kind = b"<!doctype html><title>Hello</title>HELLO AGENT", "text/html"
        self.send_response(200)
        self.send_header("Content-Type", kind)
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


class MCP:
    def __init__(self):
        env = {"SHY_AGENT_SOCKET": f"{sv.SUPPORT}/agent.sock", "PATH": "/usr/bin:/bin"}
        self.p = subprocess.Popen([HELPER], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env, text=True, bufsize=1)
        self.n = 0

    def send(self, method, params=None, notify=False):
        message = {"jsonrpc": "2.0", "method": method, "params": params or {}}
        if not notify:
            self.n += 1
            message["id"] = self.n
        self.p.stdin.write(json.dumps(message) + "\n")
        self.p.stdin.flush()
        return None if notify else json.loads(self.p.stdout.readline())

    def tool(self, name, **args):
        return self.send("tools/call", {"name": name, "arguments": args})["result"]

    def close(self):
        self.p.stdin.close()
        self.p.wait(5)


def words(result):
    return "\n".join(c.get("text", "") for c in result["content"])


def page_id(result):
    for line in words(result).splitlines():
        if line.startswith("tab_id: "):
            return line[8:]
    return ""


def main():
    t = sv.T()
    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{srv.server_port}"
    mcp = None
    try:
        sv.setup(agent=True)
        sv.launch()
        before = [x["id"] for x in sv.sp("state")["tabs"]]
        mcp = MCP()
        init = mcp.send("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "probe", "version": "1"}})
        t.ok("initialize answers with tools", "tools" in init["result"]["capabilities"], init)
        mcp.send("notifications/initialized", notify=True)
        names = [x["name"] for x in mcp.send("tools/list")["result"]["tools"]]
        t.ok("twelve tools", names == ["shy_open", "shy_text", "shy_shot", "shy_click", "shy_type", "shy_click_at", "shy_type_at", "shy_scroll", "shy_go", "shy_wait", "shy_list", "shy_close"], names)

        opened = mcp.tool("shy_open", url=f"{base}/hello")
        pid = page_id(opened)
        t.ok("open gives an id and the title", pid and "Hello" in words(opened), opened)
        t.ok("text reads the page", "HELLO AGENT" in words(mcp.tool("shy_text", tab_id=pid)))
        shot = mcp.tool("shy_shot", tab_id=pid)
        png = shot["content"][0]
        t.ok("shot is a PNG", png.get("type") == "image" and base64.b64decode(png["data"])[:8] == b"\x89PNG\r\n\x1a\n", png.get("type"))
        t.ok("none of your tabs changed", [x["id"] for x in sv.sp("state")["tabs"]] == before)

        form = page_id(mcp.tool("shy_open", url=f"{base}/form"))
        mcp.tool("shy_type", tab_id=form, selector="#name", text="Ada")
        t.ok("type fires the page's input event", "typed Ada" in words(mcp.tool("shy_text", tab_id=form)))
        mcp.tool("shy_click", tab_id=form, selector="text=Press me")
        t.ok("click by words", "clicked" in words(mcp.tool("shy_text", tab_id=form)))
        miss = mcp.tool("shy_click", tab_id=form, selector="#nothing")
        t.ok("a selector matching nothing is an error", miss.get("isError") is True, miss)

        for target in ["file:///etc/hosts", "shy://settings", "javascript:alert(1)", "data:text/html,hi", "ftp://example.com/"]:
            r = mcp.tool("shy_open", url=target)
            t.ok(f"open refuses {target.split(':')[0]}:", r.get("isError") is True, r)
            r = mcp.tool("shy_go", tab_id=form, url=target)
            t.ok(f"go refuses {target.split(':')[0]}:", r.get("isError") is True, r)

        mcp.tool("shy_click", tab_id=form, selector="#file")
        time.sleep(1)
        t.ok("a page's link to a file goes nowhere", "Form" in words(mcp.tool("shy_text", tab_id=form)))
        mcp.tool("shy_click", tab_id=form, selector="#pop")
        time.sleep(1)
        t.ok("a page's pop-up leaves the page where it was", "Form" in words(mcp.tool("shy_text", tab_id=form)))
        seen.clear()
        mcp.tool("shy_click", tab_id=form, selector="#get")
        time.sleep(1.5)
        downloads = list((Path(sv.SUPPORT) / "Downloads").glob("*")) if (Path(sv.SUPPORT) / "Downloads").exists() else []
        # The control: the click went out and the site answered with a file;
        # without it, "nothing downloaded" would pass for a click that never fired.
        t.ok("the download was asked for", "/download" in seen, seen)
        t.ok("a download is refused", not downloads, downloads)

        mcp.tool("shy_click", tab_id=form, selector="#blank")
        mcp.tool("shy_wait", tab_id=form, seconds=5)
        t.ok("a link for a new window opens in the same page", "SECOND PAGE" in words(mcp.tool("shy_text", tab_id=form)))

        # Two open: six more fit. One more would mean the pop-up made a page.
        opened = [page_id(mcp.tool("shy_open", url=f"{base}/hello")) for _ in range(8)]
        t.ok("at most eight pages, and the pop-up made none", sum(1 for x in opened if x) == 6, opened)
        closed = mcp.tool("shy_close", tab_id="all")
        t.ok("close all", "Closed 8" in words(closed), closed)
        gone = mcp.tool("shy_text", tab_id=pid)
        t.ok("a closed page is gone", gone.get("isError") is True, gone)

        # A handover: your tab signed in, a copy of its cookies in a page of
        # the agent's own, read-only, locked to its site.
        mine = sv.cmd({"do": "open", "url": f"{base}/login"})["id"]
        sv.cmd({"do": "wait", "id": mine}); time.sleep(0.5)
        sv.cmd({"do": "go", "id": mine, "url": f"{base}/me"}); sv.cmd({"do": "wait", "id": mine}); time.sleep(0.5)
        handed = sv.cmd({"do": "handover", "id": mine, "acts": False})
        t.ok("the handover copies the site's cookie", handed["cookies"] == 1, handed)
        hid = handed["page"]
        mcp.tool("shy_wait", tab_id=hid, seconds=5)
        listed = words(mcp.tool("shy_list"))
        t.ok("shy_list shows it handed over, read-only", hid in listed and "read-only" in listed, listed)
        t.ok("the agent's page is signed in", "cookie:sid=secret" in words(mcp.tool("shy_text", tab_id=hid)))
        refused = mcp.tool("shy_click", tab_id=hid, selector="#send")
        t.ok("read-only: a click is refused", refused.get("isError") is True and "read-only" in words(refused), refused)
        t.ok("read-only: nothing was sent", not any(x.startswith("POST") for x in seen), seen)
        other = base.replace("127.0.0.1", "localhost")
        mcp.tool("shy_go", tab_id=hid, url=f"{other}/me")
        state = sv.cmd({"do": "agentpage", "id": hid})
        t.ok("leaving the site removes the sign-in", not state["live"] and "left" in state["over"], state)
        t.ok("and the other site gets no cookie", "cookie:sid" not in words(mcp.tool("shy_text", tab_id=hid)))
        mcp.tool("shy_go", tab_id=hid, url=f"{base}/me")
        t.ok("back on the site, it is signed out", "cookie:sid" not in words(mcp.tool("shy_text", tab_id=hid)))
        t.ok("your tab is still signed in", "cookie:sid=secret" in sv.cmd({"do": "text", "id": mine})["text"])

        # A sign-in kept in page storage: copied too, for its origin only,
        # and wiped with the cookies.
        stash = sv.cmd({"do": "open", "url": f"{base}/store"})["id"]
        sv.cmd({"do": "wait", "id": stash}); time.sleep(0.5)
        sv.cmd({"do": "go", "id": stash, "url": f"{base}/app"}); sv.cmd({"do": "wait", "id": stash}); time.sleep(0.5)
        handed = sv.cmd({"do": "handover", "id": stash, "acts": False})
        t.ok("the handover copies its page storage", handed.get("stored") == 2, handed)
        sid = handed["page"]
        mcp.tool("shy_wait", tab_id=sid, seconds=5)
        t.ok("the agent's page has the stored sign-in", "local:tok-123 session:ses-456" in words(mcp.tool("shy_text", tab_id=sid)))
        mcp.tool("shy_go", tab_id=sid, url=f"{base}/app")
        t.ok("still there on the next page", "local:tok-123" in words(mcp.tool("shy_text", tab_id=sid)))
        mcp.tool("shy_go", tab_id=sid, url=f"{other}/app")
        t.ok("another origin gets none of it", "local:null session:null" in words(mcp.tool("shy_text", tab_id=sid)))
        # The page it left, held whole in the back-forward cache, would
        # still show the token it read: going back loads it afresh.
        mcp.tool("shy_click", tab_id=sid, selector="#back"); time.sleep(1.5)
        back = words(mcp.tool("shy_text", tab_id=sid))
        t.ok("going back after it ended shows no sign-in", "local:null session:null" in back, back)
        mcp.tool("shy_go", tab_id=sid, url=f"{base}/app")
        t.ok("back on the site, the storage is wiped", "local:null session:null" in words(mcp.tool("shy_text", tab_id=sid)))
        t.ok("your tab still has it", "local:tok-123" in sv.cmd({"do": "text", "id": stash})["text"])
        mcp.tool("shy_close", tab_id=sid)
        # Taken back while the page stays: loaded again, so a token read
        # into memory is gone with the storage.
        kept = sv.cmd({"do": "handover", "id": stash, "acts": False})["page"]
        mcp.tool("shy_wait", tab_id=kept, seconds=5)
        t.ok("handed over again, signed in", "local:tok-123" in words(mcp.tool("shy_text", tab_id=kept)))
        sv.cmd({"do": "takeback", "id": kept}); time.sleep(1.5)
        mcp.tool("shy_wait", tab_id=kept, seconds=5)
        after = words(mcp.tool("shy_text", tab_id=kept))
        t.ok("taken back, the page shows no sign-in", "local:null session:null" in after, after)
        mcp.tool("shy_close", tab_id=kept)

        # Acting, asked about: the click waits for a yes, and so does the
        # form it sends.
        acting = sv.cmd({"do": "handover", "id": mine, "acts": True, "asks": True})["page"]
        mcp.tool("shy_wait", tab_id=acting, seconds=5)
        answers = []
        def approve():
            for _ in range(2):
                for _ in range(40):
                    time.sleep(0.25)
                    try:
                        answers.append(sv.cmd({"do": "approve", "yes": True})["answered"]); break
                    except RuntimeError:
                        pass
        helper = threading.Thread(target=approve); helper.start()
        clicked = mcp.tool("shy_click", tab_id=acting, selector="#send")
        helper.join(25)
        time.sleep(1)
        t.ok("the click was asked about, then made", clicked.get("isError") is not True and answers and "Click" in answers[0], (clicked, answers))
        t.ok("the form it sent was asked about too", len(answers) == 2 and "form" in answers[1], answers)
        t.ok("the form reached the site", "POST /send" in seen, seen)
        steps = sv.cmd({"do": "agentpage", "id": acting})["steps"]
        t.ok("every step is written down", any("handed over" in x for x in steps) and any("Click" in x for x in steps), steps)
        mcp.tool("shy_close", tab_id="all")

        # Steering by the pointer: a real click at a point of the latest
        # screenshot, typing and a key, a wheel, and your clipboard kept.
        pp = page_id(mcp.tool("shy_open", url=f"{base}/pointer"))
        shot = mcp.tool("shy_shot", tab_id=pp)["content"][0]
        width = int.from_bytes(base64.b64decode(shot["data"])[16:20], "big")
        k = width / 1280
        mcp.tool("shy_click_at", tab_id=pp, x=200 * k, y=130 * k)
        t.ok("click_at presses where it points, as a real click", "clicked trusted" in words(mcp.tool("shy_text", tab_id=pp)))
        mcp.tool("shy_type_at", tab_id=pp, x=250 * k, y=320 * k, text="Hi", key="Enter")
        t.ok("type_at types into the field there, then Enter", "typed Hi enter" in words(mcp.tool("shy_text", tab_id=pp)))
        mcp.tool("shy_scroll", tab_id=pp, dy=700)
        t.ok("scroll moves the page", "scrolled 700" in words(mcp.tool("shy_text", tab_id=pp)))
        stale = mcp.tool("shy_click_at", tab_id=pp, x=200 * k, y=130 * k)
        t.ok("a point from before the page scrolled is refused", stale.get("isError") is True and "scrolled" in words(stale), stale)
        off = mcp.tool("shy_click_at", tab_id=pp, x=99999, y=5)
        t.ok("a point off the page is refused", off.get("isError") is True, off)
        mcp.tool("shy_scroll", tab_id=pp, dy=-700)
        subprocess.run(["pbcopy"], input=b"mine")
        mcp.tool("shy_click_at", tab_id=pp, x=500 * k, y=130 * k)
        time.sleep(2.2)
        kept = subprocess.run(["pbpaste"], capture_output=True).stdout
        t.ok("a page's write to the clipboard on an agent's click is undone", kept == b"mine", kept)
        mcp.tool("shy_go", tab_id=pp, url=f"{base}/hello")
        moved = mcp.tool("shy_click_at", tab_id=pp, x=200 * k, y=130 * k)
        t.ok("a point from before the page went elsewhere is refused", moved.get("isError") is True and "somewhere else" in words(moved), moved)

        # On a handed-over page that asks: a click at a point waits for a
        # yes, with a look at the spot.
        sv.cmd({"do": "go", "id": mine, "url": f"{base}/pointer"}); sv.cmd({"do": "wait", "id": mine}); time.sleep(0.5)
        asked = sv.cmd({"do": "handover", "id": mine, "acts": True, "asks": True})["page"]
        mcp.tool("shy_wait", tab_id=asked, seconds=5)
        mcp.tool("shy_shot", tab_id=asked)
        answers.clear()
        def once():
            for _ in range(40):
                time.sleep(0.25)
                try:
                    pend = sv.cmd({"do": "agentpage", "id": asked})["pending"]
                    if pend:
                        answers.append(sv.cmd({"do": "approve", "yes": True})["answered"]); return
                except RuntimeError:
                    pass
        helper = threading.Thread(target=once); helper.start()
        mcp.tool("shy_click_at", tab_id=asked, x=200 * k, y=130 * k)
        helper.join(15)
        t.ok("on a handed-over page the click at a point is asked about", answers and answers[0].startswith("Click at"), answers)
        t.ok("and made once allowed", "clicked trusted" in words(mcp.tool("shy_text", tab_id=asked)))
        mcp.tool("shy_close", tab_id="all")

    finally:
        if mcp:
            mcp.close()
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
