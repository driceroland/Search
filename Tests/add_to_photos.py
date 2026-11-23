#!/usr/bin/env python3
"""Add Image to Photos in a picture's right-click menu, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/add_to_photos.py`. Over a
picture that is also a link, a Pinterest pin's, the menu is WebKit's own and
the item is put in under Download Image (PageView.willOpenMenu). Nothing is
chosen from it, so nothing reaches the Photos library.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("add-to-photos")

# A link whose whole face is a picture, as a pin is: drawn here, so it is a
# real one.
PIN = """(function () {{
  var c = document.createElement('canvas'); c.width = 200; c.height = 200;
  c.getContext('2d').fillRect(0, 0, 200, 200);
  document.body.innerHTML = '<a href="{}"><div><img style="display:block;width:200px;height:200px" src="'
    + c.toDataURL() + '"></div></a>';
  return true;
}})()"""


def main():
    t = sv.T()
    try:
        sv.setup(); sv.launch()
        a = sv.page("a")
        sv.sp("select", id=a); time.sleep(0.4)
        sv.ev(a, PIN.format(f"{sv.BASE}/pin")); time.sleep(0.3)
        # A title no item has: the menu is read as it comes up and closed.
        r = sv.cmd({"do": "linkmenu", "id": a, "x": 60, "y": 60, "pick": "(nothing)"})
        items = r.get("menu") or []
        t.ok("a pin's menu has Add Image to Photos", "Add Image to Photos" in items, items)
        t.ok("…just under Download Image, as in Safari's",
             "Download Image" in items and "Add Image to Photos" in items
             and items.index("Add Image to Photos") == items.index("Download Image") + 1, items)
        # A plain link has no picture, and no item for one.
        sv.ev(a, f"document.body.innerHTML = '<a href=\"{sv.BASE}/plain\" style=\"display:block;"
                 f"font-size:60px;line-height:120px;padding:0 20px\">a link</a>'; true"); time.sleep(0.3)
        r = sv.cmd({"do": "linkmenu", "id": a, "x": 60, "y": 60, "pick": "(nothing)"})
        items = r.get("menu") or []
        t.ok("a plain link's menu has no Add Image to Photos", bool(items) and "Add Image to Photos" not in items, items)
    finally:
        sv.finish()
    t.done()


if __name__ == "__main__":
    main()
