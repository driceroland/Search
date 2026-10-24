#!/usr/bin/env python3
"""Imported passwords are offered under the sign-in box, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/imported_autofill.py`.

Made-up Chrome, Arc and Brave profiles go in this world's own Import/ folder
(see Chromium.base): a "Login Data" each, its passwords encrypted the way
Chromium encrypts them on the Mac (v10, AES-128-CBC, a key stretched from the
profile's own "Safe Storage" file, which a test run reads instead of the
keychain), plus a CSV as Chrome and Arc export it. Never a real browser's
files, never the real keychain's items: what is brought in is saved under this
world's label and forgotten at the end.

A local page on 127.0.0.1 and localhost holds a name and a password box; the
list under the box is read and picked through the bench's `accounts`. No
window is made or shown.
"""
import hashlib
import os
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("hub-va-pw")

PORT = 8836

LOGIN = """<!doctype html><title>sign in</title>
<form id="f" action="/done" method="post">
<input id="user" name="email" type="email" autocomplete="username">
<input id="pass" name="password" type="password" autocomplete="current-password">
<button type="submit">Sign in</button></form>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = LOGIN.encode()
        self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def log_message(self, *a): pass


def chromium_blob(password, passphrase):
    """v10 + AES-128-CBC, IV of sixteen spaces, key = PBKDF2-SHA1(passphrase,
    "saltysalt", 1003, 16): Chromium's recipe on the Mac."""
    key = hashlib.pbkdf2_hmac("sha1", passphrase.encode(), b"saltysalt", 1003, 16)
    out = subprocess.run(["openssl", "enc", "-aes-128-cbc", "-K", key.hex(), "-iv", "20" * 16],
                         input=password.encode(), capture_output=True, check=True).stdout
    return b"v10" + out


def chromium_profile(root, passphrase, rows, name="Login Data"):
    """A browser folder with one profile, "Default", and its Login Data."""
    profile = Path(root) / "Default"
    profile.mkdir(parents=True, exist_ok=True)
    (Path(root) / "Safe Storage").write_text(passphrase)
    db = sqlite3.connect(profile / name)
    # The columns Chromium has, in the order it has them, so a reader that
    # leans on any of them meets what a real file holds.
    db.execute("""CREATE TABLE logins (origin_url VARCHAR NOT NULL, action_url VARCHAR,
        username_element VARCHAR, username_value VARCHAR, password_element VARCHAR,
        password_value BLOB, submit_element VARCHAR, signon_realm VARCHAR NOT NULL,
        date_created INTEGER NOT NULL, blacklisted_by_user INTEGER NOT NULL, scheme INTEGER NOT NULL,
        password_type INTEGER, times_used INTEGER, form_data BLOB, display_name VARCHAR,
        icon_url VARCHAR, federation_url VARCHAR, skip_zero_click INTEGER, generation_upload_status INTEGER,
        possible_username_pairs BLOB, id INTEGER PRIMARY KEY AUTOINCREMENT, date_last_used INTEGER NOT NULL DEFAULT 0,
        moving_blocked_for BLOB, date_password_modified INTEGER NOT NULL DEFAULT 0, sender_email VARCHAR,
        sender_name VARCHAR, date_received INTEGER, sharing_notification_displayed INTEGER NOT NULL DEFAULT 0,
        keychain_identifier BLOB, sender_profile_image_url VARCHAR, date_last_filled INTEGER NOT NULL DEFAULT 0,
        actor_login_approved INTEGER NOT NULL DEFAULT 0)""")
    for row in rows:
        origin, realm, user, password = row[:4]
        key = row[4] if len(row) > 4 else passphrase
        db.execute("""INSERT INTO logins (origin_url, action_url, username_element, username_value,
            password_element, password_value, signon_realm, date_created, blacklisted_by_user, scheme,
            date_last_used) VALUES (?, ?, 'email', ?, 'password', ?, ?, 13370000000000000, 0, 0, 13370000000000000)""",
                   (origin, origin, user, chromium_blob(password, key), realm))
    db.commit(); db.close()


def acc(**f): return sv.cmd({"do": "accounts", **f})


def offered(tab, box="pass"):
    """The rows under the box once the caret is in it."""
    sv.ev(tab, "document.activeElement && document.activeElement.blur(); true"); time.sleep(0.4)
    sv.ev(tab, f"document.getElementById('{box}').focus(); true")
    for _ in range(20):
        r = acc()
        if r.get("shown"): return r
        time.sleep(0.15)
    return acc()


def main():
    t = sv.T()
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        sv.setup()
        imp = Path(sv.SUPPORT) / "Import"
        # Chrome: a page sent in the clear, saved with its port and path, as
        # Chrome keeps it; and an Android app's login, which is never offered.
        chromium_profile(imp / "Google/Chrome", "chrome-key", [
            (f"http://127.0.0.1:{PORT}/login", f"http://127.0.0.1:{PORT}/", "chrome@example.org", "Chrome-pw-1"),
            ("android://hash@com.example.app/", "android://hash@com.example.app/", "app@example.org", "App-pw"),
            # Encrypted with another key: counted as not decrypted, not dropped in silence.
            (f"http://127.0.0.1:{PORT}/", f"http://127.0.0.1:{PORT}/", "stale@example.org", "Stale-pw", "old-key"),
        ])
        # Chrome signed in to a Google account keeps that account's
        # passwords in a second file beside the first.
        chromium_profile(imp / "Google/Chrome", "chrome-key", [
            (f"http://127.0.0.1:{PORT}/", f"http://127.0.0.1:{PORT}/", "account@example.org", "Account-pw-5"),
        ], name="Login Data For Account")
        # Arc: the same, saved on localhost.
        chromium_profile(imp / "Arc/User Data", "arc-key", [
            (f"http://localhost:{PORT}/", f"http://localhost:{PORT}/", "arc@example.org", "Arc-pw-2"),
        ])
        # Brave: an origin with a trailing path and a www. host.
        chromium_profile(imp / "BraveSoftware/Brave-Browser", "brave-key", [
            (f"http://127.0.0.1:{PORT}/account/signin?next=/", f"http://127.0.0.1:{PORT}/", "brave@example.org", "Brave-pw-3"),
        ])
        csv = Path(tempfile.mkdtemp(prefix="hub-va-pw-")) / "Chrome Passwords.csv"
        csv.write_text("name,url,username,password,note\n"
                       f"127.0.0.1,http://127.0.0.1:{PORT}/login,csv@example.org,Csv-pw-4,\n")
        sv.launch()
        r = acc(forget=True)
        t.ok("this world keeps nothing to begin with", r.get("kept") == 0, r)

        for name, want, stale in [("Chrome", 2, 1), ("Arc", 1, 0), ("Brave", 1, 0)]:
            r = sv.cmd({"do": "import", "from": name, "what": ["passwords"]})
            t.ok(f"{name}: its passwords are read and kept", r.get("read") == want and "error" not in r, r)
            t.ok(f"{name}: what didn't decrypt is counted ({stale})", r.get("undecrypted") == stale, r)
        r = sv.cmd({"do": "import-file", "path": str(csv)})
        t.ok("the CSV's password is kept", r.get("kept") == 1, r)
        users = sorted(acc().get("users", []))
        t.ok("Settings › Passwords lists all five, the Android one left out",
             users == ["account@example.org", "arc@example.org", "brave@example.org", "chrome@example.org",
                       "csv@example.org"], users)

        # 127.0.0.1: Chrome's, Brave's and the CSV's are for this site.
        a = sv.sp("open", url=f"http://127.0.0.1:{PORT}/login")["resultID"]
        sv.sp("select", id=a); time.sleep(1.2)
        r = offered(a)
        rows = sorted(x.get("login", "") for x in r.get("rows", []))
        t.ok("the password box offers what came from Chrome (both files), Brave and the CSV",
             r.get("shown") and rows == ["account@example.org", "brave@example.org", "chrome@example.org",
                                         "csv@example.org"], r)
        r = offered(a, "user")
        t.ok("so does the name box beside it", r.get("shown") and len(r.get("rows", [])) == 4, r)
        time.sleep(0.6)
        pick = next(i for i, x in enumerate(r["rows"]) if x.get("login") == "chrome@example.org")
        acc(pick=pick); time.sleep(0.8)
        t.ok("a pick fills both boxes with Chrome's",
             sv.ev(a, "[document.getElementById('user').value, document.getElementById('pass').value]")
             == ["chrome@example.org", "Chrome-pw-1"])

        # localhost: Arc's.
        b = sv.sp("open", url=f"http://localhost:{PORT}/login")["resultID"]
        sv.sp("select", id=b); time.sleep(1.2)
        r = offered(b)
        t.ok("on localhost, Arc's is offered and nothing else",
             r.get("shown") and [x.get("login") for x in r.get("rows", [])] == ["arc@example.org"], r)
        time.sleep(0.6)
        acc(pick=0); time.sleep(0.8)
        t.ok("a pick fills Arc's", sv.ev(b, "document.getElementById('pass').value") == "Arc-pw-2")

        # Bringing them in again adds nothing twice, and is still offered.
        r = sv.cmd({"do": "import", "from": "Chrome", "what": ["passwords"]})
        t.ok("a second import keeps one copy", acc().get("kept") == 5, r)
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
