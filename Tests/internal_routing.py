"""Internal routing in an isolated Search probe. Build debug before running.

Uses real address-field submission and trusted page clicks. A loopback-only
HTTP fixture records the first destination request's profile cookie. No DNS,
real browser settings, or production test hooks are changed.
"""
import json
import socket
import subprocess
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import split_view as sv

sv.use("internal-routing")
HOST = "127.0.0.1.nip.io"
REQUESTS = []


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        REQUESTS.append((self.path, self.headers.get("Cookie", "")))
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", BASE + "/destination")
            self.end_headers()
            return
        if self.path == "/source":
            body = (f"<!doctype html><title>source</title>"
                    f"<a id='same' href='{BASE}/destination'>Same</a> "
                    f"<a id='blank' target='_blank' href='{BASE}/destination'>Blank</a> "
                    f"<form method='POST' action='{BASE}/destination'><button id='post'>Post</button></form>").encode()
        else:
            body = b"<!doctype html><title>destination</title>destination"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.do_GET()

    def log_message(self, *args):
        pass


SERVER = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
BASE = f"http://{HOST}:{SERVER.server_port}"
threading.Thread(target=SERVER.serve_forever, daemon=True).start()


def seed(policy="destination", override="inherit", enabled=True, legacy=False, port=None):
    sv.setup(spaces=True)
    work = str(uuid.uuid4()).upper()
    Path(sv.SUPPORT).mkdir(parents=True, exist_ok=True)
    Path(sv.SUPPORT, "spaces.json").write_text(json.dumps([
        {"id": sv.FIRST_SPACE, "name": "Personal", "colour": 0},
        {"id": work, "name": "Work", "colour": 1},
    ]))
    rule = {"id": str(uuid.uuid4()), "domain": HOST,
            "spaceID": work, "spaceName": "Work", "enabled": enabled}
    if port is not None:
        rule["port"] = port
    config = {"enabled": True, "rules": [rule]}
    if not legacy:
        config["internalPolicy"] = policy
        rule["internalPolicy"] = override
    subprocess.run(["defaults", "write", sv.SUITE, "external.routing", "-data",
                    json.dumps(config).encode().hex()], check=True)
    subprocess.run(["defaults", "write", sv.SUITE, "space.current", sv.FIRST_SPACE], check=True)
    sv.launch()
    # Both stores have the same origin; different cookies reveal the first request.
    for index, value in [(2, "work"), (1, "personal")]:
        sv.cmd({"do": "space", "action": "go", "index": index})
        tab = sv.cmd({"do": "open", "url": BASE + "/seed"})["id"]
        time.sleep(0.8)
        sv.ev(tab, f"document.cookie = 'profile={value}; path=/'")
    source = sv.cmd({"do": "open", "url": BASE + "/source"})["id"]
    time.sleep(0.8)
    REQUESTS.clear()
    return source


def state():
    st = sv.cmd({"do": "split", "action": "state"})
    st["space"] = sv.cmd({"do": "space"})["current"]
    return st


def settle():
    time.sleep(1.2)
    return state()


def destination_requests():
    return [cookie for path, cookie in REQUESTS if path == "/destination"]


def case(t, name, policy="destination", override="inherit", enabled=True,
         legacy=False, action="field", routed=True, port=None):
    source = seed(policy, override, enabled, legacy, port)
    if action == "private":
        source = sv.cmd({"do": "open", "url": BASE + "/source", "private": True})["id"]
        time.sleep(0.8)
        sv.ev(source, "document.cookie = 'profile=personal; path=/'")
        REQUESTS.clear()
        sv.cmd({"do": "tap", "id": source, "selector": "#same"})
    elif action == "subframe":
        sv.ev(source, f"let frame=document.createElement('iframe');frame.src='{BASE}/destination';document.body.append(frame);1")
    elif action == "redirect":
        sv.cmd({"do": "field", "text": f"http://127.0.0.1:{SERVER.server_port}/redirect", "go": True})
    elif action == "post":
        sv.cmd({"do": "tap", "id": source, "selector": "#post"})
    elif action == "external":
        sv.cmd({"do": "windows", "action": "link", "url": BASE + "/destination"})
    elif action == "field":
        sv.cmd({"do": "field", "text": BASE + "/destination", "go": True})
    elif action == "middle":
        point = sv.ev(source, "(()=>{let r=document.querySelector('#same').getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2]})()")
        sv.cmd({"do": "middle", "id": source, "x": point[0], "y": point[1]})
    elif action == "script":
        sv.ev(source, f"location.href = '{BASE}/destination'; 1")
    else:
        request = {"do": "tap", "id": source, "selector": "#blank" if action == "blank" else "#same"}
        if action == "cmd":
            request["mods"] = ["cmd"]
        sv.cmd(request)
    st = settle()
    background = action in ["cmd", "middle"]
    t.ok(name + ": active space", st["space"] == ("Work" if routed and not background else "Personal"), st)
    if routed and background:
        sv.cmd({"do": "space", "action": "go", "index": 2})
        st = settle()
    cookies = destination_requests()
    t.ok(name + ": first request uses correct store", bool(cookies) and
         all("profile=" + ("work" if routed else "personal") in c for c in cookies), cookies)
    destination = [x for x in st["tabs"] if x["url"] == BASE + "/destination"]
    t.ok(name + ": destination tab count", len(destination) == (0 if action == "subframe" else 1), destination)
    if routed:
        sv.cmd({"do": "space", "action": "go", "index": 1})
        t.ok(name + ": source preserved", any(x["id"] == source and x["url"] == BASE + "/source"
             for x in state()["tabs"]), state()["tabs"])
    sv.quit()


def main():
    global HOST, BASE
    addresses = {result[4][0] for result in socket.getaddrinfo(HOST, SERVER.server_port)}
    if addresses != {"127.0.0.1"}:
        raise RuntimeError(f"fixture host must resolve only to loopback: {addresses}")
    t = sv.T()
    try:
        original_host, original_base = HOST, BASE
        HOST = "localhost"
        BASE = f"http://{HOST}:{SERVER.server_port}"
        case(t, "localhost exact port", port=SERVER.server_port)
        case(t, "localhost external exact port", action="external", port=SERVER.server_port)
        case(t, "localhost other port excluded", port=SERVER.server_port % 65535 + 1, routed=False)
        case(t, "localhost all ports")
        HOST = "127.0.0.1"
        BASE = f"http://{HOST}:{SERVER.server_port}"
        case(t, "loopback exact port", port=SERVER.server_port)
        HOST, BASE = original_host, original_base
        for action in ["field", "same", "cmd", "blank", "middle"]:
            case(t, "automatic " + action, action=action)
        case(t, "current override", override="current", routed=False)
        case(t, "automatic override", policy="current", override="destination")
        case(t, "disabled rule", enabled=False, routed=False)
        case(t, "legacy default", legacy=True, routed=False)
        case(t, "script navigation excluded", action="script", routed=False)
        for action in ["post", "subframe", "redirect", "private"]:
            case(t, action + " excluded", action=action, routed=False)
        source = seed(policy="ask")
        sv.cmd({"do": "tap", "id": source, "selector": "#same"})
        st = settle()
        t.ok("Ask cancelled before destination request", not destination_requests(), REQUESTS)
        t.ok("Ask cancellation preserves source", st["space"] == "Personal" and
             any(x["id"] == source and x["url"] == BASE + "/source" for x in st["tabs"]), st)
        t.ok("Ask uses native dialog", "Where should this link open?" in
             sv.cmd({"do": "probe", "id": source})["dialogs"])
    finally:
        sv.finish()
        SERVER.shutdown()
    t.done()
    raise SystemExit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
