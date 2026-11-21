#!/usr/bin/env python3
"""A site asking for a client certificate gets one you chose (idea 536).

Build first (`./build.sh debug`), then `python3 Tests/client_certificate.py`.
It uses the split suite's harness: started hidden, no window made or shown,
everything removed afterwards.

A throwaway certificate authority and two client identities (one from that
authority, a decoy from another) go into a throwaway keychain, which is put
on your keychain search list for the run only — SecItemCopyMatching looks
nowhere else — and taken off again afterwards, the list restored exactly as
it was. Your login keychain is never written to. The site is `openssl
s_server` on localhost requiring a certificate: unlike Python's ssl module,
it names the authorities it accepts, as an enterprise sign-in does. Needs an
OpenSSL 1.1.1 or later (Homebrew's); skipped without one.

The picker is answered through the bench (`clientcert`): a test run never
puts a sheet up. Stopped with SIGTERM, SIGHUP or Ctrl-C it still cleans up; a run
killed outright (SIGKILL) leaves its keychain on the search list — `security
list-keychains -d user` names it (search-clientcert-…), and `security
list-keychains -d user -s <the others>` takes it off.
"""
import os
import re
import shutil
import signal
import http.server
import select
import socket
import socketserver
import threading
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bug-client-certificate")
t = sv.T()

OPENSSL = next((p for p in ["/opt/homebrew/bin/openssl", "/usr/local/bin/openssl"] if os.path.exists(p)), None)
if not OPENSSL or "LibreSSL" in subprocess.run([OPENSSL, "version"], capture_output=True, text=True).stdout:
    print("skipped: needs OpenSSL 1.1.1+ (brew install openssl)")
    sys.exit(0)

WORK = tempfile.mkdtemp(prefix="search-clientcert-")
KEYCHAIN = f"{WORK}/probe.keychain-db"
PASS = "probe-only"
MARK = "s_server"  # in every page openssl s_server -www answers with


def run(*a, **k):
    return subprocess.run(list(a), check=True, capture_output=True, text=True, cwd=WORK, **k)


def search_list():
    out = subprocess.run(["security", "list-keychains", "-d", "user"], capture_output=True, text=True).stdout
    return re.findall(r'"([^"]+)"', out)


def make_identities():
    ext = f"{WORK}/client.ext"
    Path(ext).write_text("extendedKeyUsage=clientAuth\nkeyUsage=digitalSignature\n")
    Path(f"{WORK}/srv.ext").write_text("subjectAltName=DNS:localhost\n")
    for ca in ["ca", "decoyca"]:
        run(OPENSSL, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", f"{ca}.key", "-out", f"{ca}.pem",
            "-days", "2", "-subj", f"/CN={'Probe Test CA' if ca == 'ca' else 'Probe Decoy CA'}")
    def issue(name, cn, ca, extfile):
        run(OPENSSL, "req", "-newkey", "rsa:2048", "-nodes", "-keyout", f"{name}.key", "-out", f"{name}.csr", "-subj", f"/CN={cn}")
        run(OPENSSL, "x509", "-req", "-in", f"{name}.csr", "-CA", f"{ca}.pem", "-CAkey", f"{ca}.key", "-CAcreateserial",
            "-out", f"{name}.pem", "-days", "2", "-extfile", extfile)
    issue("srv", "localhost", "ca", f"{WORK}/srv.ext")
    issue("client", "Probe Client", "ca", ext)
    issue("decoy", "Probe Decoy Client", "decoyca", ext)
    for name in ["client", "decoy"]:
        run(OPENSSL, "pkcs12", "-export", "-legacy", "-inkey", f"{name}.key", "-in", f"{name}.pem",
            "-out", f"{name}.p12", "-passout", f"pass:{PASS}", "-name", name)
    run("security", "create-keychain", "-p", PASS, KEYCHAIN)
    run("security", "set-keychain-settings", KEYCHAIN)  # no lock timeout
    run("security", "unlock-keychain", "-p", PASS, KEYCHAIN)
    for name in ["client", "decoy"]:
        run("security", "import", f"{name}.p12", "-k", KEYCHAIN, "-P", PASS, "-A")
    # The probe's own signature may use the keys without a password prompt
    # (which would be a window on the screen).
    team = re.search(r"TeamIdentifier=(\S+)", subprocess.run(["codesign", "-dv", sv.APP], capture_output=True, text=True).stderr)
    parts = "apple-tool:,apple:,unsigned:" + (f",teamid:{team.group(1)}" if team and team.group(1) != "not" else "")
    run("security", "set-key-partition-list", "-S", parts, "-s", "-k", PASS, KEYCHAIN)


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Site(socketserver.ThreadingTCPServer):
    """A site on localhost that wants a client certificate from the probe
    authority, and names it, as an enterprise sign-in does. Python's ssl
    module can't name the authorities, and `openssl s_server` can but takes
    one connection at a time — a connection WebKit opens ahead and leaves
    idle would hold up every other. So each connection here gets an
    s_server of its own (-naccept 1) and its bytes are passed through. A
    new s_server each time also means no TLS session is ever resumed: every
    connection is asked for a certificate."""
    daemon_threads = True
    allow_reuse_address = True

    class Handler(socketserver.BaseRequestHandler):
        def handle(self):
            port = free_port()
            proc = subprocess.Popen(
                [OPENSSL, "s_server", "-accept", f"127.0.0.1:{port}", "-naccept", "1", "-cert", "srv.pem", "-key", "srv.key",
                 "-CAfile", "ca.pem", "-Verify", "1", "-www", "-quiet"],
                cwd=WORK, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                for _ in range(100):
                    try:
                        back = socket.create_connection(("127.0.0.1", port), timeout=0.1); break
                    except OSError:
                        time.sleep(0.05)
                else:
                    return
                back.settimeout(None)
                ends = [self.request, back]
                while True:
                    ready, _, _ = select.select(ends, [], [], 30)
                    if not ready: return
                    for end in ready:
                        data = end.recv(65536)
                        if not data: return
                        (back if end is self.request else self.request).sendall(data)
            except OSError:
                pass
            finally:
                proc.kill(); proc.wait()


servers = {}


def serve(port):
    """The site on `port` (started once; every connection is fresh)."""
    if port not in servers:
        servers[port] = Site(("127.0.0.1", port), Site.Handler)
        threading.Thread(target=servers[port].serve_forever, daemon=True).start()
    return f"https://localhost:{port}/"


def cc(action=None, **f):
    return sv.cmd({"do": "clientcert", **({"action": action} if action else {}), **f})


def text(id):
    try:
        return sv.cmd({"do": "text", "id": id}).get("text", "")
    except RuntimeError:
        return ""


def loads(id, within=20):
    end = time.time() + within
    while time.time() < end:
        if MARK in text(id): return True
        time.sleep(0.4)
    return False


def open_tab(url, private=False, behind=False):
    """In a tab of its own, in front (split open does that); a private one
    is opened by the bench and then brought to the front; `behind` stays
    behind yours."""
    if behind:
        return sv.sp("bench", url=url)["resultID"]
    if private:
        id = sv.cmd({"do": "open", "url": url, "private": True})["id"]
        sv.cmd({"do": "select", "id": id})
        return id
    return sv.sp("open", url=url)["resultID"]


original = search_list()
for sig in (signal.SIGTERM, signal.SIGHUP):
    signal.signal(sig, lambda *_: sys.exit(1))  # through the finally below
try:
    make_identities()
    subprocess.run(["security", "list-keychains", "-d", "user", "-s", *original, KEYCHAIN], check=True)
    sv.setup(spaces=True)
    sv.launch()
    home = sv.page("home"); sv.sp("select", id=home); time.sleep(0.4)

    # Chosen: the page loads, and only the identity from the authority the
    # site names was offered.
    a = free_port(); site = serve(a)
    cc("answer", index=0)
    tab = open_tab(site)
    t.ok("choosing the identity loads the page", loads(tab), text(tab)[:200])
    st = cc()
    t.ok("the picker was asked once", len(st["asked"]) == 1, st)
    offered = st["asked"][0] if st["asked"] else []
    t.ok("only the matching identity is offered", len(offered) == 1 and "Probe Client" in offered[0]
         and "Probe Test CA" in offered[0], offered)
    t.ok("the choice is remembered for the site", f"localhost:{a}" in st["chosen"], st)

    # Remembered: a new connection (each is new here), a cancelling
    # picker, and still it loads, with no question.
    serve(a)
    cc("answer", index=None)
    again = open_tab(site)
    t.ok("the remembered choice loads the page again", loads(again), text(again)[:200])
    t.ok("without asking again", len(cc()["asked"]) == 1, cc())

    # Cancelled: nothing sent, the error page.
    b = free_port(); other = serve(b)
    no = open_tab(other)
    time.sleep(3)
    st = cc()
    t.ok("cancel asks once", len(st["asked"]) == 2, st)
    t.ok("cancel leaves the site unloaded", MARK not in text(no), text(no)[:200])
    t.ok("cancel remembers nothing", f"localhost:{b}" not in st["chosen"], st)
    # The page going on somewhere by itself doesn't bring the question back:
    # only you going somewhere does.
    serve(b)
    sv.cmd({"do": "eval", "id": no, "js": f"location.href = '{sv.BASE}/plain'; 1"}); time.sleep(1.5)
    sv.cmd({"do": "eval", "id": no, "js": f"location.href = '{other}?again'; 1"}); time.sleep(3)
    t.ok("a page sending itself on after cancel isn't asked again", len(cc()["asked"]) == 2, cc())
    # The other connections of that load weren't asked; going there again is.
    serve(b)
    sv.cmd({"do": "go", "id": no, "url": other}); time.sleep(3)
    t.ok("going there again after cancel asks again", len(cc()["asked"]) == 3, cc())

    # Private: asks even where the site was chosen, and remembers nothing.
    serve(a)
    cc("answer", index=0)
    c = free_port(); third = serve(c)
    shy = open_tab(third, private=True)
    t.ok("a private tab loads with the chosen identity", loads(shy), text(shy)[:200])
    st = cc()
    t.ok("a private tab is asked", len(st["asked"]) == 4, st)
    t.ok("a private tab's choice isn't remembered", f"localhost:{c}" not in st["chosen"], st)
    serve(a)
    shy2 = open_tab(site, private=True)
    t.ok("a private tab asks even for a site chosen in a normal tab", loads(shy2) and len(cc()["asked"]) == 5, cc())

    # A tab behind yours: the question waits for it, and closing the tab
    # answers it, with nothing sent.
    d = free_port(); fourth = serve(d)
    behind = open_tab(fourth, behind=True)
    time.sleep(3)
    st = cc()
    t.ok("a tab behind yours isn't asked over yours", len(st["asked"]) == 5 and st["open"] == 1, st)
    sv.cmd({"do": "close", "id": behind}); time.sleep(0.5)
    st = cc()
    t.ok("closing it lets the question go, answered", st["open"] == 0 and f"localhost:{d}" not in st["chosen"], st)

    # A page's own loads from a site asking (an image here): the same
    # delegate hears it, and the same picker over that tab answers it.
    e = free_port(); serve(e)
    html = f"<!doctype html><title>holder</title><img src='https://localhost:{e}/'>".encode()
    class Holder(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200); self.send_header("Content-Type", "text/html"); self.send_header("Content-Length", str(len(html)))
            self.end_headers(); self.wfile.write(html)
        def log_message(self, *a): pass
    holder = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Holder)
    threading.Thread(target=holder.serve_forever, daemon=True).start()
    cc("answer", index=0)
    sv.sp("select", id=home); time.sleep(0.4)  # not from a private tab: that opens another
    open_tab(f"http://127.0.0.1:{holder.server_port}/holder"); time.sleep(4)
    st = cc()
    t.ok("a page's image from a site asking is asked about too", len(st["asked"]) == 6 and f"localhost:{e}" in st["chosen"], st)
    holder.shutdown()

    # Another space signed in apart: what was chosen in the first isn't
    # sent from it without asking.
    serve(a)
    sv.cmd({"do": "space", "action": "new", "name": "Apart", "fresh": True}); time.sleep(1)
    apart = open_tab(site)
    t.ok("a space signed in apart is asked again", loads(apart) and len(cc()["asked"]) == 7, cc())
finally:
    try:
        sv.finish()
    finally:
        # The search list first: nothing after can keep it from going back.
        subprocess.run(["security", "list-keychains", "-d", "user", "-s", *original])
        for site in servers.values():
            site.shutdown(); site.server_close()
        subprocess.run(["security", "delete-keychain", KEYCHAIN], capture_output=True)
        shutil.rmtree(WORK, ignore_errors=True)
        restored = search_list() == original
        print("  keychain search list restored" if restored else f"  WARNING search list now {search_list()}, was {original}")
t.done()
sys.exit(1 if t.failed else 0)
