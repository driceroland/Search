"""A bookmark opens in a tab of its own, never in place of a pin (Drice, 15 Oct).

Build first (`./build.sh`), then `python3 Tests/bookmark_new_tab.py`. Hidden.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("mark-new-tab")


def tabs():
    st = sv.sp("state")
    pins = set(st.get("pins") or [])
    return [dict(x, pin=x["id"] in pins) for x in st["tabs"] if not x.get("blank")]


def main():
    t = sv.T()
    try:
        sv.setup(sidebar=True)
        sv.launch()
        a = sv.page("a")
        sv.cmd({"do": "pin", "id": a})
        sv.cmd({"do": "select", "id": a}); time.sleep(0.5)
        before = len(tabs())
        sv.cmd({"do": "openmark", "url": f"{sv.BASE}/b"}); time.sleep(1.2)
        now = tabs()
        pin = [x for x in now if x.get("pin")]
        t.ok("the pin still holds its page", len(pin) == 1 and pin[0]["url"].endswith("/a"), pin)
        t.ok("the bookmark came in a tab of its own", len(now) == before + 1 and any(x["url"].endswith("/b") and not x.get("pin") for x in now), [x["url"] for x in now])
        c = sv.page("c")
        sv.cmd({"do": "select", "id": c}); time.sleep(0.4)
        before = len(tabs())
        sv.cmd({"do": "openmark", "url": f"{sv.BASE}/d"}); time.sleep(1.2)
        now = tabs()
        t.ok("an ordinary tab keeps its page too", any(x["url"].endswith("/c") for x in now) and len(now) == before + 1, [x["url"] for x in now])
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
