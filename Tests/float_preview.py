#!/usr/bin/env python3
"""Only a video somebody watches floats out on its own (Isolate.real), and a
floated one that goes closes its window (Isolate.gone). Idea 923.

Build first (`./build.sh`), then `python3 Tests/float_preview.py`. A local
page made like YouTube's home page: a grid of thumbnails in links, each
playing a muted preview while the pointer is over it, and a player above.
Leaving the tab (the bench's `film float` via "switch", in a hidden probe,
both windows off every screen) must float nothing for a hover preview, a
muted background video, a small video or a preview with its sound on, and
must float a player playing with sound, or muted after it was heard. ⇧⌘P
still lifts a preview. Then the floated video's source is emptied, its
player hidden, or the video taken out: the window closes and the page is
back in its tab, never left black.
"""
import functools
import shutil
import sys
import tempfile
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("float-preview")

PAGE = """<!doctype html><meta charset=utf-8><title>home</title>
<style>body{margin:0;font:13px sans-serif}#top{min-height:20px}
#grid{display:grid;grid-template-columns:repeat(3,360px);gap:16px;padding:16px}
.thumbnail{position:relative;width:360px;height:202px;background:#444}
.thumbnail video{position:absolute;inset:0;width:100%;height:100%}</style>
<div id=top></div>
<div id=grid></div>
<canvas width=320 height=180 style="display:none"></canvas>
<script>
var c=document.querySelector('canvas'),g=c.getContext('2d'),n=0;
setInterval(function(){g.fillStyle='hsl('+(n++*7%360)+',70%,50%)';g.fillRect(0,0,320,180);},40);
function video(muted){var v=document.createElement('video');v.playsInline=true;v.muted=muted;v.srcObject=c.captureStream(25);return v;}
var grid=document.getElementById('grid');
for(var i=0;i<6;i++){
  var a=document.createElement('a');a.href='#watch-'+i;a.className='card';
  a.innerHTML='<div class="thumbnail"></div><p>Video '+i+'</p>';
  a.addEventListener('mouseenter',function(){var t=this.querySelector('.thumbnail');
    if(t.querySelector('video'))return;var v=video(true);v.loop=true;t.appendChild(v);v.play();});
  a.addEventListener('mouseleave',function(){var v=this.querySelector('video');if(v)v.remove();});
  grid.appendChild(a);
}
function hover(i){grid.children[i].dispatchEvent(new MouseEvent('mouseenter'));}
// A player above the grid: at a size, muted or not.
function player(w,h,muted){var box=document.createElement('div');box.id='player';
  box.style.cssText='width:'+w+'px;height:'+h+'px;background:#000;margin:16px';
  var v=video(muted);v.style.cssText='width:100%;height:100%';box.appendChild(v);
  document.getElementById('top').appendChild(box);v.play();return v;}
</script>"""

PLAYING = "(function(){var v=document.querySelectorAll('video');for(var i=0;i<v.length;i++)if(!v[i].paused&&v[i].readyState>=2)return true;return false})()"
FLOATING = "document.documentElement.classList.contains('office-floating')"


def showing():
    return sv.cmd({"do": "float", "action": "showing"}).get("showing") is True


def film(action, out, via):
    return sv.cmd({"do": "film", "action": action, "path": f"{out}/{action}-{time.time()}", "seconds": 1.2, "via": via})


def fresh(base, tab, setup):
    """The page anew, in front, with `setup` run and something playing."""
    sv.cmd({"do": "select", "id": tab})
    sv.ev(tab, f"location.replace('{base}/home.html?' + Date.now()); 1")
    time.sleep(2)
    sv.ev(tab, setup + "; 1")
    for _ in range(40):
        if sv.ev(tab, PLAYING) is True:
            break
        time.sleep(0.25)
    time.sleep(1)


def leave(out, tab):
    """Over to the other tab, as ⌃Tab does, and whether the video floated."""
    film("float", out, "switch")
    time.sleep(0.8)
    return showing()


def home(out, tab):
    """Back to the tab, the video landing if it floated."""
    if showing():
        film("land", out, "switch")
        time.sleep(1.5)
    sv.cmd({"do": "select", "id": tab})
    time.sleep(0.5)


def main():
    pages = tempfile.mkdtemp(prefix="search-float-preview-")
    Path(pages, "home.html").write_text(PAGE)
    Path(pages, "other.html").write_text("<!doctype html><meta charset=utf-8><title>other</title><p>another page")

    class Quiet(SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass
    server = ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=pages))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    out = tempfile.mkdtemp(prefix="search-float-preview-film-")
    base = f"http://127.0.0.1:{server.server_port}"
    t = sv.T()
    try:
        sv.setup(); sv.launch()
        sv.cmd({"do": "window"}); time.sleep(1)
        sv.sp("open", url=f"{base}/other.html")
        tab = sv.sp("open", url=f"{base}/home.html")["resultID"]

        # Nothing floats that nobody is watching.
        for name, setup in [
            ("a muted hover preview", "hover(0)"),
            ("a muted background video", "player(960,540,true)"),
            ("a small video with sound", "player(160,90,false)"),
            ("a hover preview with its sound on", "hover(1); var p=document.querySelector('.thumbnail video'); p.muted=false"),
        ]:
            fresh(base, tab, setup)
            up = leave(out, tab)
            t.ok(f"leaving the tab during {name} floats nothing", not up, up)
            home(out, tab)

        # A player somebody watches floats, whatever previews play beside it.
        for name, setup in [
            ("a player with sound", "player(960,540,false)"),
            ("a player with sound, a preview playing beside it", "player(960,540,false); hover(2)"),
            ("a player muted after it was heard", "var v=player(960,540,false); setTimeout(function(){v.muted=true},400)"),
        ]:
            fresh(base, tab, setup)
            up = leave(out, tab)
            marked = sv.ev(tab, "(function(){var v=document.querySelector('[data-office-float]');return !!v && !!v.closest('#player')})()")
            t.ok(f"leaving the tab during {name} floats it", up and marked is True, (up, marked))
            home(out, tab)

        # ⇧⌘P, by hand, still lifts a preview.
        fresh(base, tab, "hover(3)")
        film("float", out, "key")
        time.sleep(0.8)
        t.ok("⇧⌘P still floats a hover preview", showing())
        if showing():
            film("land", out, "key")
            time.sleep(1.5)

        # A floated video that goes closes its window, and the page is back.
        for name, end in [
            ("its source emptied", "var v=document.querySelector('#player video'); v.srcObject=null; v.removeAttribute('src'); v.load()"),
            ("its player hidden, as a preview ends", "document.getElementById('player').style.display='none'"),
            ("it taken out of the page", "document.querySelector('#player video').remove()"),
        ]:
            fresh(base, tab, "player(960,540,false)")
            up = leave(out, tab)
            if not up:
                t.ok(f"{name}: floated first", False)
                home(out, tab)
                continue
            time.sleep(1.5)
            still = showing()
            sv.ev(tab, end + "; 1")
            closed = None
            for i in range(40):
                if not showing():
                    closed = round(i * 0.1, 1)
                    break
                time.sleep(0.1)
            time.sleep(1.5)
            back = sv.ev(tab, FLOATING)
            t.ok(f"{name}: the window stays while it plays, then closes", still and closed is not None and closed < 3.5, (still, closed))
            t.ok(f"{name}: and the page is out of the floating state", back is False, back)
            home(out, tab)
    finally:
        t.done(); sv.finish()
        server.shutdown()
        shutil.rmtree(pages, ignore_errors=True); shutil.rmtree(out, ignore_errors=True)
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
