#!/usr/bin/env python3
"""Exercise bookmark replacement in a named, throwaway SEARCH_PROBE world.

Build the current debug app bundle and run with:

    ./tests/bookmark-import-regression.py

The app reads only the fake profiles below Search (<unique world>)/Import.
"""

import json
import os
import plistlib
import shutil
import sqlite3
import subprocess
import tempfile
import time
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "build" / "Search.app"
BENCH = ROOT / "bench"


def require(condition, message):
    if not condition:
        raise AssertionError(message)


class BookmarkImportRegression:
    def __init__(self):
        self.world = f"bookmark-reg-{os.getpid()}-{uuid.uuid4().hex[:8]}"
        self.suite = f"com.officecommun.search.test.{self.world}"
        self.folder = Path.home() / "Library/Application Support" / f"Search ({self.world})"
        self.imports = self.folder / "Import"
        self.bookmarks_file = self.folder / "bookmarks.json"
        self.manual_id = str(uuid.uuid4()).upper()

    def run(self, *args, check=True):
        result = subprocess.run(
            [str(BENCH), "--world", self.world, *args],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        if check and result.returncode:
            raise AssertionError(f"bench {' '.join(args)} failed: {result.stderr.strip()}")
        return result

    def start(self):
        # Reassemble from this checkout on every run so the probe cannot use a
        # stale app bundle left by an earlier build.
        subprocess.run(["./build.sh", "debug"], cwd=ROOT, check=True)

        # SEARCH_PROBE permits the socket in this world without changing the
        # user's normal browser settings or touching its browser profiles.
        subprocess.run(["defaults", "write", self.suite, "bench", "-bool", "YES"], check=True)
        self.seed_manual_bookmark()
        self.make_chromium_profiles()
        self.make_mozilla_profile("Good", "https://firefox-old.test/", "Firefox old")

        subprocess.run(
            ["open", "-g", "-j", "-n", "--env", f"SEARCH_PROBE={self.world}", str(APP)],
            cwd=ROOT,
            check=True,
        )
        deadline = time.monotonic() + 35
        last = ""
        while time.monotonic() < deadline:
            result = self.run("probe", check=False)
            if result.returncode == 0:
                return
            last = result.stderr.strip()
            time.sleep(0.25)
        raise AssertionError(f"the isolated Search probe did not start: {last}")

    def seed_manual_bookmark(self):
        self.folder.mkdir(parents=True, exist_ok=True)
        # A bookmark without an ImportRecord stands in for one the person
        # added themselves. Replacement must leave its UUID and position alone.
        self.bookmarks_file.write_text(
            json.dumps(
                [
                    {
                        "id": self.manual_id,
                        "title": "Manual bookmark",
                        "url": "https://manual.test/",
                    }
                ]
            ),
            encoding="utf-8",
        )

    def chrome_profile(self, name):
        path = self.imports / "Google/Chrome" / name
        path.mkdir(parents=True, exist_ok=True)
        # Chromium's profile discovery also recognizes History. Keeping it
        # makes a deleted Bookmarks file a selected, unreadable profile.
        (path / "History").write_bytes(b"")
        return path

    @staticmethod
    def chromium_data(entries):
        return json.dumps(
            {
                "roots": {
                    "bookmark_bar": {"children": entries},
                    "other": {"children": []},
                    "synced": {"children": []},
                }
            }
        )

    def write_chrome_bookmarks(self, path, entries):
        (path / "Bookmarks").write_text(self.chromium_data(entries), encoding="utf-8")

    def make_chromium_profiles(self):
        root = self.imports / "Google/Chrome"
        root.mkdir(parents=True, exist_ok=True)
        (root / "Local State").write_text(
            json.dumps({"profile": {"last_used": "Default"}}), encoding="utf-8"
        )
        default = self.chrome_profile("Default")
        self.write_chrome_bookmarks(
            default,
            [{"type": "url", "name": "Chrome old", "url": "https://chrome-old.test/"}],
        )
        self.default_chrome = default

    @staticmethod
    def sqlite_bookmarks(path, entry=None):
        path.parent.mkdir(parents=True, exist_ok=True)
        for suffix in ("", "-wal", "-shm"):
            Path(str(path) + suffix).unlink(missing_ok=True)
        connection = sqlite3.connect(path)
        connection.executescript(
            """
            CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT);
            CREATE TABLE moz_bookmarks (
                id INTEGER PRIMARY KEY, type INTEGER, parent INTEGER, title TEXT,
                fk INTEGER, guid TEXT, position INTEGER
            );
            INSERT INTO moz_bookmarks VALUES (1, 2, 0, 'root', NULL, 'root________', 0);
            INSERT INTO moz_bookmarks VALUES (2, 2, 1, 'toolbar', NULL, 'toolbar_____', 1);
            INSERT INTO moz_bookmarks VALUES (3, 2, 1, 'menu', NULL, 'menu________', 2);
            INSERT INTO moz_bookmarks VALUES (4, 2, 1, 'unfiled', NULL, 'unfiled_____', 3);
            INSERT INTO moz_bookmarks VALUES (5, 2, 1, 'mobile', NULL, 'mobile______', 4);
            """
        )
        if entry:
            url, title = entry
            connection.execute("INSERT INTO moz_places VALUES (1, ?)", (url,))
            connection.execute(
                "INSERT INTO moz_bookmarks VALUES (6, 1, 2, ?, 1, 'page_______', 5)",
                (title,),
            )
        connection.commit()
        connection.close()

    def make_mozilla_profile(self, name, url, title):
        path = self.imports / "Firefox/Profiles" / name
        self.sqlite_bookmarks(path / "places.sqlite", (url, title))
        return path

    def preference_records(self):
        with tempfile.TemporaryDirectory(prefix="search-bookmark-records-") as temporary:
            exported = Path(temporary) / "preferences.plist"
            subprocess.run(["defaults", "export", self.suite, str(exported)], check=True)
            values = plistlib.loads(exported.read_bytes())
        return values.get("import.records")

    def snapshot(self):
        # Let an erroneous asynchronous bookmark save reach disk before the
        # before/after comparison.
        time.sleep(0.6)
        data = self.bookmarks_file.read_bytes() if self.bookmarks_file.exists() else None
        return data, self.preference_records()

    def records(self):
        raw = self.preference_records()
        return json.loads(raw) if raw else {}

    def urls(self):
        raw = self.bookmarks_file.read_bytes()
        roots = json.loads(raw)
        found = []

        def walk(nodes):
            for node in nodes:
                if node.get("url"):
                    found.append(node["url"])
                walk(node.get("children") or [])

        walk(roots)
        return found

    def wait_for_urls(self, expected, label):
        expected = set(expected)
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            try:
                if set(self.urls()) == expected:
                    return
            except (FileNotFoundError, json.JSONDecodeError):
                pass
            time.sleep(0.1)
        raise AssertionError(f"{label}: bookmarks did not settle to {sorted(expected)}")

    def expect_import(self, *args):
        result = self.run("import", *args)
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise AssertionError(f"bench import returned no JSON: {result.stdout}") from error

    def expect_failure_preserves_state(self, label, *args):
        before = self.snapshot()
        result = self.run("import", *args, check=False)
        require(result.returncode != 0, f"{label}: import unexpectedly succeeded")
        after = self.snapshot()
        require(before == after, f"{label}: bookmarks.json or import.records changed")

    def test_chromium(self):
        self.expect_import("Chrome", "bookmarks", "--profile", "Default")
        self.wait_for_urls(["https://manual.test/", "https://chrome-old.test/"], "initial Chrome import")
        old_chrome_ids = self.records()["Chrome"]["bookmarkIDs"]
        require(len(old_chrome_ids) == 2, "the initial Chrome import was not recorded")
        require("https://chrome-old.test/" in self.urls(), "the initial Chrome bookmark is absent")

        # A selected profile still exists (History remains) after its source
        # file goes missing. That must fail before taking back its old import.
        (self.default_chrome / "Bookmarks").unlink()
        self.expect_failure_preserves_state("missing Chromium Bookmarks", "Chrome", "bookmarks", "--profile", "Default", "--replace")

        (self.default_chrome / "Bookmarks").write_text('{"roots":', encoding="utf-8")
        self.expect_failure_preserves_state("corrupt Chromium JSON", "Chrome", "bookmarks", "--profile", "Default", "--replace")

        (self.default_chrome / "Bookmarks").write_text(
            json.dumps({"roots": {"bookmark_bar": {"children": "not an array"}}}),
            encoding="utf-8",
        )
        self.expect_failure_preserves_state("malformed Chromium structure", "Chrome", "bookmarks", "--profile", "Default", "--replace")

        (self.default_chrome / "Bookmarks").write_text(
            json.dumps({"roots": {"bookmark_bar": {"children": [{}]}}}),
            encoding="utf-8",
        )
        self.expect_failure_preserves_state("invalid Chromium bookmark node", "Chrome", "bookmarks", "--profile", "Default", "--replace")

        # An empty but valid source is a successful replacement: Chrome's
        # imported tree goes away, the manual bookmark and its ID remain.
        self.write_chrome_bookmarks(self.default_chrome, [])
        self.expect_import("Chrome", "bookmarks", "--profile", "Default", "--replace")
        self.wait_for_urls(["https://manual.test/"], "empty Chrome replacement")
        require(self.urls() == ["https://manual.test/"], "empty Chrome replacement removed or changed the manual bookmark")
        require(json.loads(self.bookmarks_file.read_bytes())[0]["id"] == self.manual_id, "manual bookmark UUID changed")
        chrome_record = self.records()["Chrome"]
        require(chrome_record["bookmarks"] == 0 and chrome_record["bookmarkIDs"] == [], "empty Chrome replacement left imported IDs recorded")

        # A new valid source replaces cleanly and keeps the manual bookmark.
        self.write_chrome_bookmarks(
            self.default_chrome,
            [{"type": "url", "name": "Chrome new", "url": "https://chrome-new.test/"}],
        )
        self.expect_import("Chrome", "bookmarks", "--profile", "Default", "--replace")
        self.wait_for_urls(["https://manual.test/", "https://chrome-new.test/"], "valid Chrome replacement")
        require(set(self.urls()) == {"https://manual.test/", "https://chrome-new.test/"}, "valid Chrome replacement did not swap only Chrome's imported bookmark")

        self.write_chrome_bookmarks(
            self.default_chrome,
            [{"type": "url", "name": "Chrome replacement", "url": "https://chrome-replacement.test/"}],
        )
        self.expect_import("Chrome", "bookmarks", "--profile", "Default", "--replace")
        self.wait_for_urls(["https://manual.test/", "https://chrome-replacement.test/"], "nonempty Chrome replacement")

        # An all-profile replacement reads both healthy profiles and merges
        # them into one record, then a broken profile must abort atomically.
        broken = self.chrome_profile("Profile 1")
        (broken / "Bookmarks").write_text('{"roots":', encoding="utf-8")
        self.expect_failure_preserves_state("all-profile Chromium failure", "Chrome", "bookmarks", "--profile", "all", "--replace")

        self.write_chrome_bookmarks(
            self.default_chrome,
            [{"type": "url", "name": "Chrome profile A", "url": "https://chrome-profile-a.test/"}],
        )
        self.write_chrome_bookmarks(
            broken,
            [{"type": "url", "name": "Chrome profile B", "url": "https://chrome-profile-b.test/"}],
        )
        self.expect_import("Chrome", "bookmarks", "--profile", "all", "--replace")
        self.wait_for_urls(
            ["https://manual.test/", "https://chrome-profile-a.test/", "https://chrome-profile-b.test/"],
            "healthy all-profile Chrome replacement",
        )

        # A selected, readable profile can still be replaced when another
        # profile directory is inaccessible; all-profile replacement must
        # fail because it cannot account for every profile.
        broken.chmod(0)
        try:
            self.expect_import("Chrome", "bookmarks", "--profile", "Default", "--replace")
            self.wait_for_urls(["https://manual.test/", "https://chrome-profile-a.test/"], "selected Chrome replacement with inaccessible sibling")
            self.expect_failure_preserves_state("unreadable Chromium profile directory", "Chrome", "bookmarks", "--profile", "all", "--replace")
        finally:
            broken.chmod(0o700)

    def test_mozilla(self):
        self.expect_import("Firefox", "bookmarks", "--profile", "Good")
        self.wait_for_urls(["https://manual.test/", "https://chrome-profile-a.test/", "https://firefox-old.test/"], "initial Firefox import")
        require("https://firefox-old.test/" in self.urls(), "the initial Firefox import is absent")

        # The primary database is readable, but a present WAL cannot be read
        # or copied. Snapshot must treat the pair as one failed source.
        wal = Path(str(self.imports / "Firefox/Profiles/Good/places.sqlite") + "-wal")
        if os.geteuid() != 0:
            wal.write_bytes(b"unreadable sqlite wal")
            wal.chmod(0)
            try:
                self.expect_failure_preserves_state("unreadable Firefox WAL", "Firefox", "bookmarks", "--profile", "Good", "--replace")
            finally:
                wal.chmod(0o600)
                wal.unlink(missing_ok=True)

        # The all-profile read encounters one complete profile and one
        # SQLite file whose required query cannot be prepared.
        broken = self.imports / "Firefox/Profiles/Broken"
        broken.mkdir(parents=True, exist_ok=True)
        db = sqlite3.connect(broken / "places.sqlite")
        db.execute("CREATE TABLE moz_bookmarks (id INTEGER)")
        db.close()
        os.utime(broken / "places.sqlite", (time.time() - 20, time.time() - 20))
        os.utime(self.imports / "Firefox/Profiles/Good/places.sqlite", None)
        self.expect_failure_preserves_state("all-profile Mozilla failure", "Firefox", "bookmarks", "--profile", "all", "--replace")

        shutil.rmtree(broken)
        self.sqlite_bookmarks(self.imports / "Firefox/Profiles/Good/places.sqlite")
        self.expect_import("Firefox", "bookmarks", "--profile", "Good", "--replace")
        self.wait_for_urls(["https://manual.test/", "https://chrome-profile-a.test/"], "empty Firefox replacement")
        require(set(self.urls()) == {"https://manual.test/", "https://chrome-profile-a.test/"}, "valid empty Firefox replacement removed another source's bookmarks")
        firefox_record = self.records()["Firefox"]
        require(firefox_record["bookmarks"] == 0 and firefox_record["bookmarkIDs"] == [], "empty Firefox replacement left imported IDs recorded")

        self.sqlite_bookmarks(
            self.imports / "Firefox/Profiles/Good/places.sqlite",
            ("https://firefox-new.test/", "Firefox new"),
        )
        self.expect_import("Firefox", "bookmarks", "--profile", "Good", "--replace")
        self.wait_for_urls(["https://manual.test/", "https://chrome-profile-a.test/", "https://firefox-new.test/"], "valid Firefox replacement")
        require(set(self.urls()) == {"https://manual.test/", "https://chrome-profile-a.test/", "https://firefox-new.test/"}, "valid Firefox replacement did not replace its own source")

    def cleanup(self):
        self.run("quit", check=False)
        deadline = time.monotonic() + 12
        socket = self.folder / "bench.sock"
        while socket.exists() and time.monotonic() < deadline:
            time.sleep(0.2)
        shutil.rmtree(self.folder, ignore_errors=True)
        subprocess.run(["defaults", "delete", self.suite], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        # Store.probeStore(1), for this unique world.
        value = 2166136261
        for byte in self.world.encode():
            value = ((value ^ byte) * 16777619) & 0xFFFFFFFF
        identifier = f"5E4C{value >> 16:04X}-{value & 0xFFFF:04X}-4000-8000-000000000001"
        webkit = Path.home() / "Library/WebKit/com.officecommun.search/WebsiteDataStore" / identifier
        shutil.rmtree(webkit, ignore_errors=True)

    def test(self):
        try:
            self.start()
            self.test_chromium()
            self.test_mozilla()
        finally:
            self.cleanup()


if __name__ == "__main__":
    regression = BookmarkImportRegression()
    regression.test()
    print("bookmark import regression passed")
