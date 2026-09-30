#!/usr/bin/env python3
"""A page opens a window only on the heels of a click, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/popups.py`. It runs in
split_view.py's test world, with its harness: started hidden, everything
removed afterwards.
"""
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# draw.io's Authorize asks its server first and opens the sign-in window
# with the answer: "late" is that, two seconds after the click.
PAGE = """<!doctype html><title>popups</title>
<button id=late style="width:200px;height:60px">late</button>
<button id=slow style="width:200px;height:60px">slow</button>
<script>
window.log = [];
setTimeout(() => log.push('onload:' + (open('about:blank#a', 'a') != null)), 300);
late.onclick = () => setTimeout(() => {
  log.push('late:' + (open('about:blank#b', 'b') != null));
  log.push('second:' + (open('about:blank#c', 'c') != null));
}, 2000);
slow.onclick = () => setTimeout(() => log.push('slow:' + (open('about:blank#d', 'd') != null)), 6000);
</script>"""

t = sv.T()
def tap(id, selector): sv.cmd({"do": "tap", "id": id, "selector": selector})
try:
    sv.setup(); sv.launch()
    id = sv.cmd({"do": "open", "url": "data:text/html," + urllib.parse.quote(PAGE)})["id"]
    time.sleep(1.5)
    tap(id, "#late"); time.sleep(3)
    tap(id, "#slow"); time.sleep(7)
    log = sv.ev(id, "log.join(' ')") or ""
    t.ok("no window on load, with no click", "onload:false" in log, log)
    t.ok("a window two seconds after a click", "late:true" in log, log)
    t.ok("one window for one click", "second:false" in log, log)
    t.ok("no window six seconds after a click", "slow:false" in log, log)
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
