#!/usr/bin/env python3
"""A song floated (Float.swift, Isolate.on), as YouTube Music plays one.

Build first (`./build.sh`), then `python3 Tests/float_song.py`. YouTube
Music plays a song through a video that is hidden or has no picture at all,
and shows the album's cover beside it; floated as a video, the little window
showed the player's buttons and tabs instead (idea 802). Each local page
here plays such a video beside a player's buttons that make themselves
visible, as YouTube Music's do. The isolation script runs on an ordinary tab
of a hidden probe — the floating window itself is never opened — and the
page must then show the song's cover over the whole view, or, with no cover
anywhere, not float at all.
"""
import functools
import json
import struct
import sys
import tempfile
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("float-song")

ROOT = Path(__file__).resolve().parents[1]

# The player: the cover where the page shows it, the song's video hidden
# beside it, and buttons that make themselves visible whatever their
# ancestors say — those were what the little window showed.
PAGE = """<!doctype html><meta charset=utf-8><title>{name}</title>
<style>body{{margin:0}} .controls button{{visibility:visible;width:60px;height:40px}}</style>
<div class=player style="position:relative;width:640px;margin:40px auto">
{cover}
<div class=video-box><video muted playsinline style="{video_style}"></video></div>
<div class=controls><button>shuffle</button><button>prev</button><button>pause</button><button>next</button><button>repeat</button></div>
<div class=controls><button>Up next</button><button>Lyrics</button></div>
</div>
<canvas width=320 height=180 style="display:none"></canvas>
<script>
var v=document.querySelector('video');
{source}
v.play();
{meta}
</script>"""
COVER = '<img class=cover src="/cover.svg" style="width:300px;height:300px;display:block">'
SONG = "v.src='/tone.wav'; v.loop=true;"
FILM = """var c=document.querySelector('canvas'),g=c.getContext('2d'),n=0;
setInterval(function(){g.fillStyle='hsl('+(n++*7%360)+',70%,50%)';g.fillRect(0,0,c.width,c.height);},40);
v.srcObject=c.captureStream(25);"""
META = """navigator.mediaSession.metadata=new MediaMetadata({title:'Song',artist:'Band',
artwork:[{src:'/art-96.svg',sizes:'96x96',type:'image/svg+xml'},{src:'/art-512.svg',sizes:'512x512',type:'image/svg+xml'}]});"""
CASES = {
    # A song with no picture, its video hidden, and the cover shown beside it.
    "song-hidden": dict(cover=COVER, video_style="display:none", source=SONG, meta=""),
    # A song with no picture in a video of ordinary size, the cover beside it.
    "song-empty": dict(cover=COVER, video_style="width:640px;height:360px", source=SONG, meta=""),
    # A video with a picture, but kept at no size, and the cover given to
    # Now Playing: the largest of those.
    "song-zero": dict(cover="", video_style="width:0;height:0", source=FILM, meta=META),
    # Both: Now Playing's cover first.
    "song-both": dict(cover=COVER, video_style="display:none", source=SONG, meta=META),
}
NOTHING = dict(cover="", video_style="display:none", source=SONG, meta="")

SVG = """<svg xmlns="http://www.w3.org/2000/svg" width="{n}" height="{n}"><rect width="100%" height="100%" fill="{fill}"/></svg>"""

# The cover over the whole view, in front of the buttons: the buttons are
# hit through it only if nothing covers them.
PROBE = """(function(){var a=document.getElementById('office-float-art');
if(!a)return JSON.stringify({art:null,floating:document.documentElement.classList.contains('office-floating'),marked:!!document.querySelector('[data-office-float]')});
var r=a.getBoundingClientRect(),s=getComputedStyle(a),b=document.querySelector('.controls button').getBoundingClientRect();
a.style.setProperty('pointer-events','auto','important');
var hit=document.elementFromPoint(Math.min(b.left+5,innerWidth-1),Math.min(b.top+5,innerHeight-1));
var mid=document.elementFromPoint(innerWidth/2,innerHeight/2);
a.style.removeProperty('pointer-events');
return JSON.stringify({art:a.getAttribute('src'),x:r.left,y:r.top,w:r.width,h:r.height,iw:innerWidth,ih:innerHeight,
vis:s.visibility,disp:s.display,fit:s.objectFit,covers:hit===a&&mid===a,
playing:!document.querySelector('video').paused,marked:!!document.querySelector('video[data-office-float]')})})()"""


def tone():
    """Thirty seconds of a quiet tone, as a WAV file: audio and no picture."""
    rate, seconds = 8000, 30
    frames = bytes((128 + (20 if (i // 20) % 2 else -20)) for i in range(rate * seconds))
    head = b"RIFF" + struct.pack("<I", 36 + len(frames)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate, 1, 8)
    return head + b"data" + struct.pack("<I", len(frames)) + frames


def main():
    pages = tempfile.mkdtemp(prefix="search-float-song-")
    Path(pages, "tone.wav").write_bytes(tone())
    Path(pages, "cover.svg").write_text(SVG.format(n=300, fill="#c33"))
    Path(pages, "art-96.svg").write_text(SVG.format(n=96, fill="#3c3"))
    Path(pages, "art-512.svg").write_text(SVG.format(n=512, fill="#33c"))
    Path(pages, "art-next.svg").write_text(SVG.format(n=512, fill="#cc3"))
    for name, parts in {**CASES, "song-nothing": NOTHING}.items():
        Path(pages, f"{name}.html").write_text(PAGE.format(name=name, **parts))

    class Quiet(SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass
    server = ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=pages))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    source = (ROOT / "Sources/Search/Float.swift").read_text()
    start = source.index('static let on = """') + len('static let on = """')
    isolate = source[start:source.index('"""', start)].strip().replace("\\\\", "\\")
    start = source.index('static let off = """') + len('static let off = """')
    restore = source[start:source.index('"""', start)].strip().replace("\\\\", "\\")
    playing = "(function(){var v=document.querySelector('video');return !!v&&!v.paused&&v.readyState>=2})()"
    expected = {"song-hidden": "/cover.svg", "song-empty": "/cover.svg", "song-zero": "/art-512.svg", "song-both": "/art-512.svg"}
    t = sv.T()
    try:
        sv.setup(); sv.launch()
        for name in [*CASES, "song-nothing"]:
            tab = sv.sp("open", url=f"{base}/{name}.html")["resultID"]
            sv.cmd({"do": "resize", "width": 1180, "height": 780, "steps": 2})
            for _ in range(40):
                if sv.cmd({"do": "eval", "id": tab, "js": playing})["value"] is True:
                    break
                time.sleep(0.25)
            t.ok(f"{name}: the song plays", sv.cmd({"do": "eval", "id": tab, "js": playing})["value"] is True)
            said = sv.cmd({"do": "eval", "id": tab, "js": isolate, "world": "search"}).get("value")
            if name == "song-nothing":
                p = json.loads(sv.cmd({"do": "eval", "id": tab, "js": PROBE})["value"])
                t.ok("song-nothing: with no cover anywhere, nothing floats", said == "none" and p["art"] is None and not p["floating"] and not p["marked"], (said, p))
                sv.sp("close", id=tab)
                continue
            floating = isinstance(said, dict) and said.get("floating") is True
            t.ok(f"{name}: floats, with no frame to cut a still from", floating and "alone" not in said, said)
            for width, height in [(440, 247), (700, 500), (300, 300)]:
                sv.cmd({"do": "resize", "width": width, "height": height, "steps": 2})
                time.sleep(0.3)
                p = json.loads(sv.cmd({"do": "eval", "id": tab, "js": PROBE})["value"])
                fills = p.get("art") is not None and abs(p["x"]) < 1 and abs(p["y"]) < 1 and abs(p["w"] - p["iw"]) < 1 and abs(p["h"] - p["ih"]) < 1
                t.ok(f"{name} {width}x{height}: the cover fills the view, over the buttons",
                     fills and p["art"].endswith(expected[name]) and p["vis"] == "visible" and p["disp"] == "block"
                     and p["fit"] == "contain" and p["covers"] and p["playing"] and p["marked"], p)
            if "art-512" in expected[name]:
                # The next song: its cover, once the page has it.
                sv.cmd({"do": "eval", "id": tab, "js": "navigator.mediaSession.metadata=new MediaMetadata({title:'Next',artwork:[{src:'/art-next.svg',sizes:'512x512'}]}); 1"})
                time.sleep(2.5)
                p = json.loads(sv.cmd({"do": "eval", "id": tab, "js": PROBE})["value"])
                t.ok(f"{name}: the next song's cover follows", (p.get("art") or "").endswith("/art-next.svg"), p)
            sv.cmd({"do": "resize", "width": 1180, "height": 780, "steps": 2})
            sv.cmd({"do": "eval", "id": tab, "js": restore, "world": "search"})
            time.sleep(1.2)
            p = json.loads(sv.cmd({"do": "eval", "id": tab, "js": PROBE})["value"])
            t.ok(f"{name}: back in its tab, the cover is gone and the song plays on", p["art"] is None and not p["floating"] and not p["marked"]
                 and sv.cmd({"do": "eval", "id": tab, "js": playing})["value"] is True, p)
            sv.sp("close", id=tab)
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
