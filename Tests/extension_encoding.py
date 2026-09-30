#!/usr/bin/env python3
"""Packaged scripts keep their Unicode when injected into a legacy page.

Build first (`./build.sh debug`), then `python3 Tests/extension_encoding.py`.
Uses a real unpacked extension, WebKit, and a local HTTP server; no wallet
or browser API is mocked. All browser state belongs to the test world.
"""
import json
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import split_view as sv


TEXT = "ÇĞİıŞü АЯ αω 🤔"
SCRIPT = "globalThis.extensionEncoding = {text: " + json.dumps(TEXT, ensure_ascii=False) + ", matches: /^[一-龠]+$/.test('一龠')};"


class Pages(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/site.js":
            body = "globalThis.siteText = 'café';".encode("windows-1252")
            mime = "text/javascript; charset=windows-1252"
        else:
            body = b'<!doctype html><title>Encoding test</title><script src="/site.js"></script>'
            charset = "utf-8" if self.path == "/utf8" else "windows-1252"
            mime = "text/html; charset=" + charset
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def until(read, ready, timeout=15):
    deadline = time.monotonic() + timeout
    value = None
    while time.monotonic() < deadline:
        value = read()
        if ready(value):
            return value
        time.sleep(0.1)
    return value


def main():
    sv.use("extension-encoding")
    checks = sv.T()
    server = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    tabs = []
    try:
        with tempfile.TemporaryDirectory(prefix="search-encoding-") as temporary:
            folder = Path(temporary)
            manifest = {
                "manifest_version": 3, "name": "Script encoding test", "version": "1.0",
                "content_scripts": [{"matches": ["http://127.0.0.1/*"],
                                     "js": ["content.js"], "run_at": "document_start"}],
                "web_accessible_resources": [{"matches": ["http://127.0.0.1/*"],
                                              "resources": ["provider.js"]}],
            }
            (folder / "manifest.json").write_text(json.dumps(manifest))
            (folder / "provider.js").write_text(SCRIPT, encoding="utf-8")
            untouched = {
                "ascii.js": b"globalThis.asciiScript = true;",
                "legacy.js": b"const text = 'caf\xe9';",
                "hashbang.js": "#!/usr/bin/env node\nconst text = 'café';".encode(),
                "data.txt": TEXT.encode(),
            }
            for name, content in untouched.items():
                (folder / name).write_bytes(content)
            (folder / "module.mjs").write_text("export const text = " + json.dumps(TEXT, ensure_ascii=False), encoding="utf-8")
            (folder / "marked.js").write_bytes(b"\xef\xbb\xbf" + SCRIPT.encode())
            (folder / "content.js").write_text('''
const script = document.createElement('script');
script.src = chrome.runtime.getURL('provider.js');
document.documentElement.appendChild(script);
''')
            sv.setup()
            sv.launch()
            sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
            installed = until(lambda: sv.cmd({"do": "extensions"}),
                              lambda r: not r["busy"] and any(e["loaded"] and e["source"] == str(folder) for e in r["extensions"]))
            assert any(e["loaded"] and e["source"] == str(folder) for e in installed["extensions"]), installed
            extension = next(e for e in installed["extensions"] if e["source"] == str(folder))
            prepared = Path(sv.SUPPORT) / "Extensions" / extension["id"]
            checks.ok("unrelated encodings, ASCII, hashbang and data keep their bytes",
                      all((prepared / name).read_bytes() == content for name, content in untouched.items()))
            checks.ok("an existing UTF-8 signature is preserved",
                      (prepared / "marked.js").read_bytes() == (folder / "marked.js").read_bytes())
            for path, charset in [("/legacy", "windows-1252"), ("/utf8", "UTF-8")]:
                tab = sv.cmd({"do": "open", "url": f"http://127.0.0.1:{server.server_port}{path}"})["id"]
                tabs.append(tab)
                state = until(lambda: json.loads(sv.ev(tab, '''JSON.stringify({charset:document.characterSet,
                    provider:window.extensionEncoding,siteText:window.siteText})''')),
                    lambda r: "provider" in r and "siteText" in r, timeout=5)
                checks.ok(path + ": extension text and Unicode regex survive",
                          state.get("provider") == {"text": TEXT, "matches": True}, state)
                checks.ok(path + ": site encoding and script are preserved",
                          state.get("charset") == charset and state.get("siteText") == "café", state)
            before = {name: (prepared / name).read_bytes() for name in ["provider.js", "module.mjs", "marked.js", "content.js"]}
            # Exercise an installed package after a shim upgrade, rather than
            # Reload (which copies the original unpacked folder again).
            for tab in tabs:
                sv.cmd({"do": "close", "id": tab})
            tabs.clear()
            sv.quit()
            (prepared / ".search-shim").write_text("previous-preparation-version")
            sv.launch()
            reloaded = until(lambda: sv.cmd({"do": "extensions"}),
                             lambda r: any(e["id"] == extension["id"] and e["loaded"] for e in r["extensions"]))
            checks.ok("the installed extension is prepared and loaded again",
                      any(e["id"] == extension["id"] and e["loaded"] for e in reloaded["extensions"])
                      and (prepared / ".search-shim").read_text() != "previous-preparation-version", reloaded)
            checks.ok("repreparing an installed extension preserves its scripts",
                      all((prepared / name).read_bytes() == content for name, content in before.items()))
    finally:
        try:
            sv.finish()
        finally:
            server.shutdown()
            server.server_close()
            sv.srv.shutdown()
            sv.srv.server_close()
            checks.done()
    return bool(checks.failed)


if __name__ == "__main__":
    sys.exit(main())
