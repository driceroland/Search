#!/usr/bin/env python3
"""./bench-mcp, spoken to as an agent's client would: over stdio, against a
page served from this run.

Build first (`./build.sh`), then `python3 Tests/bench_mcp.py`. The server
starts the build hidden in a fresh world of its own and wipes it when the
session closes; checked here, along with the handles failing rather than
guessing (a covered button, a handle from the read before, a second
controller on the same world), a password's value never leaving the page,
typing checked against the field, real clicks and key events, wait_for,
navigation, a screenshot, and the raw bench passthrough. And the line the
server holds: it drives only worlds it started. A world something else
has open is refused, and a session whose process was replaced under it
gets nothing.
"""

import base64
import json
import os
import secrets
import shutil
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parents[1]
VERBOSE = "-v" in sys.argv

FORM = """<!doctype html><title>form</title>
<h1>Sign up</h1>
<form action="/done" method="get">
  <label>Name <input name="name" id="name"></label>
  <label>Password <input type="password" name="pw" value="hunter2-secret"></label>
  <label><input type="checkbox" id="agree"> Agree</label>
  <button id="go">Send</button>
</form>
<div style="position:relative;display:inline-block">
  <button id="under">Under</button>
  <div style="position:absolute;inset:0;background:rgba(255,255,255,.5)"></div>
</div>
<button id="later" type="button" onclick="setTimeout(function () {
  document.body.insertAdjacentHTML('beforeend', '<p>Arrived late</p>') }, 500)">Later</button>
"""


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/done":
            name = parse_qs(url.query).get("name", [""])[0]
            body = f"<!doctype html><title>done</title><p>Hello {name}</p>"
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

server = subprocess.Popen([str(ROOT / "bench-mcp")], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
counter = 0


def rpc(method, params=None):
    global counter
    counter += 1
    server.stdin.write(json.dumps({"jsonrpc": "2.0", "id": counter, "method": method, "params": params or {}}) + "\n")
    server.stdin.flush()
    answer = json.loads(server.stdout.readline())
    assert answer["id"] == counter, answer
    return answer["result"]


def tool(which, /, **args):
    """→ (what it said, as JSON or the content list; whether it was an error)"""
    out = rpc("tools/call", {"name": which, "arguments": args})
    if VERBOSE:
        print(f"  {which} {json.dumps(args)[:120]} → {json.dumps(out)[:300]}")
    content = out["content"]
    if len(content) == 1 and content[0]["type"] == "text":
        return json.loads(content[0]["text"]), bool(out.get("isError"))
    return content, bool(out.get("isError"))


def code(said):
    return said.get("error", {}).get("code") if isinstance(said, dict) else None


def node(read, role, name):
    return next((n for n in read["nodes"] if n["role"] == role and n["name"] == name), None)


passed = failed = 0


def ok(name, cond, extra=""):
    global passed, failed
    if cond:
        passed += 1
        print(f"  ok  {name}")
    else:
        failed += 1
        print(f"FAIL  {name} {extra}")


session = None
try:
    init = rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t"}})
    ok("initialize", init["serverInfo"]["name"] == "search-bench" and init["protocolVersion"] == "2025-06-18")
    names = {t["name"] for t in rpc("tools/list")["tools"]}
    ok("every tool listed", {"open_session", "read_page", "click", "type", "wait_for", "bench"} <= names, names)

    said, err = tool("list_tabs", session="ses_nope")
    ok("no session, no tabs", err and code(said) == "stale_session", said)

    said, err = tool("open_session")
    ok("open_session starts a world", not err and said.get("started") and said["world"].startswith("agent-"), said)
    session, world = said["session"], said["world"]
    support = os.path.expanduser(f"~/Library/Application Support/Search ({world})")

    said, err = tool("open_session", world=world)
    ok("a second controller is refused", err and code(said) == "world_busy", said)

    tab, err = tool("open_tab", session=session, url=f"{BASE}/form")
    ok("open_tab loads", not err and tab["title"] == "form" and not tab["loading"], tab)
    page = tab["page"]

    read, err = tool("read_page", session=session, page=page)
    ok("read_page", not err and node(read, "heading", "Sign up"), read)
    ok("a password's value stays in the page", "hunter2" not in json.dumps(read))
    pw = node(read, "textbox", "Password")
    ok("the password field says it is filled", pw and pw.get("redacted") and pw.get("filled"), pw)
    name, agree = node(read, "textbox", "Name"), node(read, "checkbox", "Agree")
    under, later, send = node(read, "button", "Under"), node(read, "button", "Later"), node(read, "button", "Send")
    ok("controls named by their labels", all([name, agree, under, later, send]), read["nodes"])

    said, err = tool("click", session=session, element=under["element"])
    ok("a covered button is not clicked", err and code(said) == "obscured", said)

    said, err = tool("type", session=session, element=name["element"], text="Ada")
    ok("type sets and checks", not err and said.get("verified"), said)
    said, err = tool("type", session=session, element=name["element"], text=" Lovelace", replace=False)
    ok("type appends", not err and said.get("verified"), said)
    said, err = tool("type", session=session, element=name["element"], text="Grace", keys=True)
    ok("type with real keys replaces", not err and said.get("verified"), said)

    said, err = tool("click", session=session, element=agree["element"])
    ok("a real click", not err and said.get("trusted") and not said.get("navigated"), said)
    again, _ = tool("read_page", session=session, page=page, text=False)
    ok("the click ticked the box", node(again, "checkbox", "Agree").get("checked") is True, again)
    ok("typed value read back", node(again, "textbox", "Name").get("value") == "Grace")
    said, err = tool("click", session=session, element=agree["element"])
    ok("a handle from the read before is stale", err and code(said) == "stale_element", said)

    said, err = tool("click", session=session, element=node(again, "button", "Later")["element"])
    said, err = tool("wait_for", session=session, page=page, text="Arrived late", timeout=5)
    ok("wait_for text", not err and said.get("met"), said)
    said, err = tool("wait_for", session=session, page=page, role="button", name="send")
    ok("wait_for role and name", not err and said.get("met"), said)
    said, err = tool("wait_for", session=session, page=page, text="Never here", timeout=1)
    ok("wait_for times out as an error", err and code(said) == "timeout", said)

    said, err = tool("click", session=session, element=node(again, "button", "Send")["element"])
    ok("a click that navigates", not err and said.get("navigated") and said["title"] == "done", said)
    said, err = tool("wait_for", session=session, page=page, text="Hello Grace")
    ok("the form went with the typed name", not err, said)
    said, err = tool("type", session=session, element=name["element"], text="x")
    ok("handles end with the read that made them", err and code(said) == "stale_element", said)

    said, err = tool("back", session=session, page=page)
    ok("back", not err and said["url"].endswith("/form"), said)
    said, err = tool("navigate", session=session, page=page, url=f"{BASE}/done?name=Nav")
    ok("navigate", not err and said["title"] == "done", said)

    shot, err = tool("screenshot", session=session, page=page)
    png = base64.b64decode(shot[0]["data"]) if not err else b""
    ok("screenshot is a PNG", png[:8] == b"\x89PNG\r\n\x1a\n", shot if err else shot[1])

    said, err = tool("evaluate", session=session, page=page, js="document.title + ' ' + (1 + 1)")
    ok("evaluate", not err and said["value"] == "done 2", said)
    said, err = tool("bench", session=session, request={"do": "text", "id": page})
    ok("bench passthrough takes a page handle", not err and "Hello Nav" in said.get("text", ""), said)
    said, err = tool("bench", session=session, request={"do": "quit"})
    ok("bench passthrough leaves quitting to close_session", err and code(said) == "bad_request", said)
    said, err = tool("bench", session=session, request={"do": "update", "action": "check"})
    ok("bench passthrough refuses the updater", err and code(said) == "bad_request", said)
    said, err = tool("window_state", session=session)
    ok("window_state", not err and isinstance(said, dict), said)

    said, err = tool("close_tab", session=session, page=page)
    ok("close_tab", not err, said)
    said, err = tool("read_page", session=session, page=page)
    ok("a closed page's handle is stale", err and code(said) == "stale_page", said)

    said, err = tool("close_session", session=session)
    session = None
    ok("close_session quits and wipes", not err and said.get("quit") and said.get("wiped"), said)
    ok("the world's folder is gone", not os.path.exists(support), support)
    domain = f"com.officecommun.search.test.{world}"
    left = subprocess.run(["defaults", "read", domain], capture_output=True, text=True, check=False)
    # An emptied domain can still be listed, as {}.
    ok("the world's settings are gone", left.returncode != 0 or left.stdout.strip() in ("", "{\n}", "{}"), left.stdout)
finally:
    if session:
        tool("close_session", session=session)
    server.stdin.close()
    server.wait(timeout=30)

# A client that goes without closing its session: the server closes it.
server = subprocess.Popen([str(ROOT / "bench-mcp")], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t"}})
said, err = tool("open_session")
left = os.path.expanduser(f"~/Library/Application Support/Search ({said.get('world')})")
server.stdin.close()
server.wait(timeout=60)
ok("a session left open goes with the server", not err and not os.path.exists(left), said)


# Worlds started behind the server's back, the way fresh.sh starts one.
def support(world):
    return os.path.expanduser(f"~/Library/Application Support/Search ({world})")


def holders(world):
    sock = f"{support(world)}/bench.sock"
    if not os.path.exists(sock):
        return set()
    return set(subprocess.run(["lsof", "-t", "--", sock], capture_output=True, text=True, check=False).stdout.split())


def raw(world, request):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as c:
        c.settimeout(30)
        c.connect(f"{support(world)}/bench.sock")
        c.sendall(json.dumps(request).encode() + b"\n")
        data = b""
        while chunk := c.recv(65536):
            data += chunk
    return json.loads(data.split(b"\n", 1)[0] or b"{}")


def start(world):
    for key in ("bench", "welcomed"):
        subprocess.run(["defaults", "write", f"com.officecommun.search.test.{world}", key, "-bool", "true"], check=True)
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={world}", str(ROOT / "build/Search.app")], check=True)
    for _ in range(300):
        try:
            if "tabs" in raw(world, {"do": "tabs"}):
                return
        except OSError:
            pass
        time.sleep(0.1)
    raise RuntimeError(f"{world} never listened")


def stop(world, wipe=True):
    try:
        raw(world, {"do": "quit"})
    except OSError:
        pass
    for _ in range(50):
        if not holders(world):
            break
        time.sleep(0.2)
    if wipe:
        h = 2166136261
        for byte in world.encode():
            h = ((h ^ byte) * 16777619) & 0xFFFFFFFF
        store = f"5E4C{h >> 16:04X}-{h & 0xFFFF:04X}-4000-8000-"
        webkit = os.path.expanduser("~/Library/WebKit/com.officecommun.search")
        shutil.rmtree(f"{webkit}/WebsiteDataStore/{store.lower()}000000000001", ignore_errors=True)
        shutil.rmtree(f"{webkit}/WebExtensions/{store}000000000002", ignore_errors=True)
        shutil.rmtree(support(world), ignore_errors=True)
        subprocess.run(["defaults", "delete", f"com.officecommun.search.test.{world}"], capture_output=True, check=False)


server = subprocess.Popen([str(ROOT / "bench-mcp")], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t"}})
other = f"mcp-other-{secrets.token_hex(3)}"
session = None
try:
    start(other)
    said, err = tool("open_session", world=other)
    ok("a world something else has open is refused", err and code(said) == "world_in_use", said)
    ok("and left running", holders(other) and "tabs" in raw(other, {"do": "tabs"}))
    stop(other)

    # The session's own process gone, and the same world opened again by
    # something else: the session's handle reaches nothing.
    said, err = tool("open_session")
    session, world = said["session"], said["world"]
    for pid in holders(world):
        subprocess.run(["kill", pid], check=False)
    for _ in range(50):
        if not holders(world):
            break
        time.sleep(0.2)
    start(world)
    said, err = tool("list_tabs", session=session)
    ok("a world replaced under its session is not driven", err and code(said) == "not_ours", said)
    said, err = tool("bench", session=session, request={"do": "tabs"})
    ok("not through the passthrough either", err and code(said) == "not_ours", said)
    stop(world, wipe=False)
    said, err = tool("close_session", session=session)
    session = None
    ok("its session still closes and wipes", not err and not os.path.exists(support(world)), said)
finally:
    if session:
        tool("close_session", session=session)
    if holders(other):
        stop(other)
    server.stdin.close()
    server.wait(timeout=60)

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
