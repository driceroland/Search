#!/usr/bin/env python3
"""⌘R reloads a page that uses the same key, in a hidden probe (#1667).

Build with `./build.sh`, then run `python3 Tests/reload_shortcut.py`.
The page takes ⌘R like Google Sheets does. Search reloads it by default
and leaves the key to the page once Reload Page's shortcut is cleared.
"""
import json
import subprocess
import sys
import time

import keyboard
import split_view as sv


sv.use("reload-key")


def watch_reload_key(tab):
    return sv.ev(tab, """
        window.__keys = [];
        window.addEventListener('keydown', event => {
            if (event.metaKey && !event.altKey && !event.ctrlKey && !event.shiftKey && event.key === 'r') {
                window.__keys.push(event.key);
                event.preventDefault();
            }
        }, true);
        true
    """)


def navigation(tab):
    return sv.ev(tab, "document.readyState === 'complete' && performance.getEntriesByType('navigation')[0]?.type")


def wait_for_reload(tab):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if navigation(tab) == "reload":
            return True
        time.sleep(0.1)
    return False


def main():
    t = sv.T()
    code = keyboard.code("r")
    if code is None:
        raise RuntimeError("No key types r on the active keyboard layout")
    press = {"do": "keyeq", "code": code, "chars": "r"}
    try:
        sv.setup(**{"privacy.httpsFirst": False}); sv.launch()
        tab = sv.page("reload-default")
        t.ok("the page is ready to take ⌘R", watch_reload_key(tab) is True)
        result = sv.cmd(press)
        t.ok("⌘R goes to Reload Page ahead of the site's shortcut", result.get("firstPass") == "search", result)
        t.ok("the page reloads", wait_for_reload(tab), navigation(tab))

        sv.quit(); sv.setup(**{"privacy.httpsFirst": False})
        subprocess.run(["defaults", "write", sv.SUITE, "shortcuts", "-data",
                        b'{"view.reload":{}}'.hex()], check=True)
        sv.launch()
        tab = sv.page("reload-cleared")
        t.ok("the page is ready with the shortcut cleared", watch_reload_key(tab) is True)
        result = sv.cmd(press)
        t.ok("clearing Reload Page gives ⌘R back to the page",
             result.get("firstPass") == "page" and json.loads(result.get("pageSaw") or "[]") == ["r"], result)
        t.ok("the page keeps its original navigation", navigation(tab) == "navigate", result)
    finally:
        t.done(); sv.finish()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
