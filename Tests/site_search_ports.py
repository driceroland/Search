#!/usr/bin/env python3
"""Past searches for shortcuts on different ports, through the address field.

Build first (`./build.sh`), then run `python3 Tests/site_search_ports.py`.
The hidden test profile seeds history without visiting the search URLs.
"""
import json
import subprocess
import sys
from uuid import UUID

import split_view as sv


sv.use("site-search-ports")


def main():
    t = sv.T()
    try:
        sv.setup(**{"privacy.httpsFirst": False, "search.suggest": False})
        shortcuts = [
            {"id": str(UUID(int=i)), "keyword": keyword,
             "template": f"http://{host}/search?q=%s"}
            for i, (keyword, host) in enumerate([
                ("devone", "localhost:3000"),
                ("devtwo", "localhost:4000"),
                ("devdefault", "localhost"),
            ], 1)
        ]
        subprocess.run(["defaults", "write", sv.SUITE, "search.keywords", "-data",
                        json.dumps(shortcuts).encode().hex()], check=True)
        sv.launch()
        sv.page("start")
        for host, words in [("localhost:3000", "spring%20first"),
                            ("localhost:4000", "spring%20second"),
                            ("localhost:80", "spring%20explicit"),
                            ("localhost", "spring%20implicit")]:
            sv.cmd({"do": "history", "take": f"http://{host}/search?q={words}"})

        # Replace the whole text without emptying the field or dismissing it.
        # A cache keyed by host alone would reuse the first shortcut's words.
        for keyword, words in [("devone", {"spring first"}),
                               ("devtwo", {"spring second"}),
                               ("devdefault", {"spring explicit", "spring implicit"}),
                               ("devone", {"spring first"})]:
            field = sv.cmd({"do": "field", "text": f"{keyword} spring"})
            t.ok(f"the same field now holds {keyword}", field["typed"] == f"{keyword} spring", field)
            offers = sv.cmd({"do": "suggest"})["offers"]
            past = {title for title, kind, _ in offers if kind == "searched"}
            t.ok(f"{keyword} only suggests searches from its port",
                 past == {f"{keyword} {query}" for query in words}, offers)

        # The same words on both ports still take you to two different pages.
        shared = {f"http://localhost:{port}/search?q=octopus" for port in (3000, 4000)}
        for url in sorted(shared):
            sv.cmd({"do": "history", "take": url})
        sv.cmd({"do": "field", "text": "octopus"})
        offers = sv.cmd({"do": "suggest"})["offers"]
        t.ok("the plain field keeps identical terms from different ports",
             {url for title, kind, url in offers if title == "octopus" and kind == "searched"} == shared, offers)
    finally:
        t.done()
        sv.finish()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
