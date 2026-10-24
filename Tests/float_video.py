#!/usr/bin/env python3
"""The floating video's isolation (Float.swift, Isolate.on) on local pages.

Build first (`./build.sh`), then `python3 Tests/float_video.py`. Each page
holds a playing video under an ancestor that makes a box of its own for
fixed elements (a transform, a filter, containment…), is drawn only when on
screen, or is faded out. Video styles also exercise minimum sizes, spacing,
clips and masks, across viewport resizes and return. The isolation script runs
on an ordinary tab of a hidden probe — the floating window itself is never opened — and the video
must then fill the page's view, as `contain` fits it, and be visible.
Native preparation is also checked without opening a floating window: it
must preserve the source geometry, and reject sources that need those repairs.
"""
import functools
import json
import sys
import tempfile
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("float-video")

ROOT = Path(__file__).resolve().parents[1]
CASES = {
    "plain": "",
    "transform": "transform:translateZ(0);",
    "filter": "filter:blur(0px);",
    "contain": "contain:paint;",
    "will-change": "will-change:transform;",
    "content-visibility": "content-visibility:auto; contain-intrinsic-size:auto 300px;",
    "opacity": "opacity:0;",
    "perspective": "perspective:100px;",
    "backdrop": "backdrop-filter:blur(1px);",
    "container": "container-type:inline-size;",
}
VIDEO_CASES = {
    "video-minimum": "min-width:2400px;min-height:1400px;",
    "video-margin": "margin:80px;",
    "video-padding-border": "padding:40px;border:20px solid red;box-sizing:content-box;",
    "video-clip": "clip-path:inset(20%);",
    "video-portrait": "",
    # Twitch's Studio mode: the video as tall as the page, its picture in the
    # middle between black bars.
    "video-studio": "height:160%;",
    "video-mask": "mask:linear-gradient(transparent,black);",
}
ANCESTOR_CASES = {
    # The whole picture is within the CSS viewport, but paint containment
    # clips it even though the ancestor explicitly permits overflow.
    "ancestor-paint": ("width:320px;height:180px;contain:paint;overflow:visible;", "width:640px;height:360px;"),
    # The picture matches the parent's border rectangle, not the smaller
    # padding rectangle to which overflow actually clips it.
    "ancestor-border": ("box-sizing:border-box;border:20px solid red;", "position:relative;left:-20px;top:-20px;width:640px;height:360px;"),
    "ancestor-rounded": ("border-radius:80px;", ""),
}
PAGE = """<!doctype html><meta charset=utf-8><title>{name}</title>
<style>body{{margin:0}} .feed>div{{height:600px;border-bottom:1px solid #ccc}}</style>
<div class=feed><div>post</div><div>post</div>
<div style="position:relative;width:640px;height:360px;margin:40px auto;overflow:hidden;{style}">
<div style="position:absolute;inset:0"><video muted playsinline style="width:100%;height:100%;{video_style}"></video></div></div>
<div>post</div><div>post</div></div>
<canvas width=320 height=180 style="display:none"></canvas>
<script>
var c=document.querySelector('canvas'),g=c.getContext('2d'),n=0;
setInterval(function(){{g.fillStyle='hsl('+(n++*7%360)+',70%,50%)';g.fillRect(0,0,c.width,c.height);}},40);
var v=document.querySelector('video'); v.srcObject=c.captureStream(25); v.play();
window.scrollTo(0,500);
</script>"""
# Where the picture is, as `contain` fits it inside the video's box: that is
# what has to fill the view, whatever is around it.
PROBE = """(function(){var v=document.querySelector('video');var b=v.getBoundingClientRect();
var f=v.videoWidth&&v.videoHeight?Math.min(b.width/v.videoWidth,b.height/v.videoHeight):0;
var w=f?v.videoWidth*f:b.width,h=f?v.videoHeight*f:b.height,r={left:b.left+(b.width-w)/2,top:b.top+(b.height-h)/2,width:w,height:h};
var seen=v.checkVisibility?v.checkVisibility({contentVisibilityAuto:true,opacityProperty:true,visibilityProperty:true}):true;
return JSON.stringify({x:r.left,y:r.top,w:r.width,h:r.height,iw:innerWidth,ih:innerHeight,seen:seen,fit:getComputedStyle(v).objectFit,playing:!v.paused,clip:getComputedStyle(v).clipPath,mask:getComputedStyle(v).webkitMaskImage})})()"""

SOURCE_PROBE = """(function(){var v=document.querySelector('video'),b=v.getBoundingClientRect();
return JSON.stringify({box:[b.left,b.top,b.width,b.height],page:[innerWidth,innerHeight],scroll:[scrollX,scrollY],
style:v.getAttribute('style'),playing:!v.paused&&!v.ended,native:document.documentElement.classList.contains('office-float-native'),
floating:document.documentElement.classList.contains('office-floating'),marked:v.hasAttribute('data-office-float')})})()"""


def source_state(tab):
    return json.loads(sv.cmd({"do": "eval", "id": tab, "js": SOURCE_PROBE})["value"])


def same_source(before, after):
    return all(abs(a - b) < 0.1 for key in ("box", "page", "scroll")
               for a, b in zip(before[key], after[key])) and before["style"] == after["style"]

# Twitch's chat column, as far as the floating video sees it: Studio mode
# folds it away in a narrow page and never opens it again by itself.
CHAT = """<div class="right-column"><div class="right-column__toggle-visibility">
<button data-a-target="right-column__toggle-collapse-btn">chat</button></div></div>
<script>
var column=document.querySelector('.right-column');
column.querySelector('button').onclick=function(){column.classList.toggle('right-column--collapsed')};
addEventListener('resize',function(){if(innerWidth<920)column.classList.add('right-column--collapsed')});
</script>"""
CHAT_OPEN = "!!document.querySelector('.right-column:not(.right-column--collapsed)')"


def main():
    pages = tempfile.mkdtemp(prefix="search-float-")
    for name, style in CASES.items():
        Path(pages, f"{name}.html").write_text(PAGE.format(name=name, style=style, video_style=""))
    for name, style in VIDEO_CASES.items():
        page = PAGE.format(name=name, style="", video_style=style)
        if name == "video-portrait":
            page = page.replace("width=320 height=180", "width=180 height=320")
        Path(pages, f"{name}.html").write_text(page)
    for name, (style, video_style) in ANCESTOR_CASES.items():
        Path(pages, f"{name}.html").write_text(PAGE.format(name=name, style=style, video_style=video_style))
    portrait = PAGE.format(name="native-portrait", style="", video_style="object-fit:contain;")
    Path(pages, "native-portrait.html").write_text(portrait.replace("width=320 height=180", "width=180 height=320"))
    Path(pages, "twitch-chat.html").write_text(PAGE.format(name="twitch-chat", style="", video_style="") + CHAT)
    class Quiet(SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass
    handler = functools.partial(Quiet, directory=pages)
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    source = (ROOT / "Sources/Search/Float.swift").read_text()
    start = source.index('"""', source.index('static func on(nativeCrop:')) + 3
    prepare = source[start:source.index('"""', start)].strip().replace("\\\\", "\\")
    if r"\(nativeCrop)" not in prepare:
        raise RuntimeError("Isolate.on no longer exposes the nativeCrop interpolation")
    isolate = prepare.replace(r"\(nativeCrop)", "false")
    native_isolate = prepare.replace(r"\(nativeCrop)", "true")
    start = source.index('static let off = """') + len('static let off = """')
    restore = source[start:source.index('"""', start)].strip().replace("\\\\", "\\")
    styling = "JSON.stringify(['minWidth','minHeight','marginTop','paddingTop','borderTopWidth','clipPath','webkitMaskImage'].map(k=>getComputedStyle(document.querySelector('video'))[k]))"
    t = sv.T()
    try:
        sv.setup(); sv.launch()
        for name in [*CASES, *VIDEO_CASES]:
            tab = sv.sp("open", url=f"{base}/{name}.html")["resultID"]
            time.sleep(1.5)
            before = sv.cmd({"do": "eval", "id": tab, "js": styling})["value"]
            said = sv.cmd({"do": "eval", "id": tab, "js": isolate, "world": "search"}).get("value")
            for width, height in [(1180, 780), (700, 500), (900, 900)]:
                sv.cmd({"do": "resize", "width": width, "height": height, "steps": 2})
                p = json.loads(sv.cmd({"do": "eval", "id": tab, "js": PROBE}).get("value"))
                # The picture as large as it goes whole, in the middle: one way
                # it fills the view, the other it is centred.
                wide = abs(p["x"]) < 1 and abs(p["w"] - p["iw"]) < 1 and abs(2 * p["y"] + p["h"] - p["ih"]) < 2 and p["h"] <= p["ih"] + 1
                tall = abs(p["y"]) < 1 and abs(p["h"] - p["ih"]) < 1 and abs(2 * p["x"] + p["w"] - p["iw"]) < 2 and p["w"] <= p["iw"] + 1
                floating = isinstance(said, dict) and said.get("floating") is True
                t.ok(f"{name} {width}x{height}: video fits without clipping", floating and (wide or tall) and p["seen"] and p["playing"] and p["fit"] == "contain" and p["clip"] == "none" and p["mask"] == "none", p)
            sv.cmd({"do": "eval", "id": tab, "js": restore, "world": "search"})
            time.sleep(1.1)
            after = sv.cmd({"do": "eval", "id": tab, "js": styling})["value"]
            t.ok(f"{name}: returning restores the player's styles", before == after, after)
            sv.sp("close", id=tab)

        for name in ("plain", "native-portrait"):
            tab = sv.sp("open", url=f"{base}/{name}.html")["resultID"]
            sv.cmd({"do": "resize", "width": 1180, "height": 780, "steps": 2})
            time.sleep(1.5)
            sv.cmd({"do": "eval", "id": tab, "js": "scrollTo(0,1200)"})
            before = source_state(tab)
            said = sv.cmd({"do": "eval", "id": tab, "js": native_isolate, "world": "search"}).get("value")
            after = source_state(tab)
            native = isinstance(said, dict) and said.get("floating") is True and said.get("native") is True
            t.ok(f"{name}: native preparation preserves source geometry, scroll and playback",
                 native and before["scroll"][1] == 1200 and same_source(before, after)
                 and before["playing"] and after["playing"] and after["native"] and after["marked"],
                 {"said": said, "before": before, "after": after})
            box = before["box"]
            # The portrait picture is centred inside the unchanged landscape
            # element. The crop describes that picture, without its side bars.
            picture_width = box[3] * 180 / 320 if name == "native-portrait" else box[2]
            expected = [box[0] + (box[2] - picture_width) / 2, box[1], picture_width, box[3]]
            picture = said.get("picture", []) if isinstance(said, dict) else []
            t.ok(f"{name}: native crop selects the complete picture at its intrinsic aspect",
                 native and len(picture) == 4 and all(abs(a - b) < 0.1 for a, b in zip(picture, expected))
                 and said.get("page") == before["page"], {"picture": picture, "expected": expected})
            sv.cmd({"do": "eval", "id": tab, "js": restore, "world": "search"})
            time.sleep(1.1)
            returned = source_state(tab)
            t.ok(f"{name}: returning preserves the source and clears native isolation",
                 same_source(before, returned) and returned["playing"] and not returned["native"]
                 and not returned["floating"] and not returned["marked"], returned)
            sv.sp("close", id=tab)

        # Native geometry is measured before the page changes owners. If the
        # source size changes in that interval, fitting can be prepared again
        # on the very same page instead of using the stale native measurement.
        tab = sv.sp("open", url=f"{base}/plain.html")["resultID"]
        sv.cmd({"do": "resize", "width": 1180, "height": 780, "steps": 2})
        time.sleep(1.5)
        sv.cmd({"do": "eval", "id": tab, "js": "scrollTo(0,1200)"})
        before = sv.cmd({"do": "eval", "id": tab, "js": styling})["value"]
        native = sv.cmd({"do": "eval", "id": tab, "js": native_isolate, "world": "search"}).get("value")
        sv.cmd({"do": "resize", "width": 700, "height": 500, "steps": 2})
        resized = source_state(tab)
        t.ok("reprepare: the source changes size after a successful native measurement",
             isinstance(native, dict) and native.get("native") is True and resized["native"]
             and native.get("page") != resized["page"], {"native": native, "resized": resized})
        said = sv.cmd({"do": "eval", "id": tab, "js": isolate, "world": "search"}).get("value")
        p = json.loads(sv.cmd({"do": "eval", "id": tab, "js": PROBE})["value"])
        wide = abs(p["x"]) < 1 and abs(p["w"] - p["iw"]) < 1 and abs(2 * p["y"] + p["h"] - p["ih"]) < 2 and p["h"] <= p["ih"] + 1
        tall = abs(p["y"]) < 1 and abs(p["h"] - p["ih"]) < 1 and abs(2 * p["x"] + p["w"] - p["iw"]) < 2 and p["w"] <= p["iw"] + 1
        t.ok("reprepare: fallback replaces native isolation with a complete visible contain fit",
             isinstance(said, dict) and said.get("floating") is True and said.get("native") is False
             and not source_state(tab)["native"] and (wide or tall) and p["seen"] and p["playing"]
             and p["fit"] == "contain" and p["clip"] == "none" and p["mask"] == "none",
             {"said": said, "probe": p})
        sv.cmd({"do": "eval", "id": tab, "js": restore, "world": "search"})
        time.sleep(1.1)
        after = sv.cmd({"do": "eval", "id": tab, "js": styling})["value"]
        returned = source_state(tab)
        t.ok("reprepare: returning restores player styles and clears both isolation modes",
             before == after and returned["playing"] and not returned["native"]
             and not returned["floating"] and not returned["marked"], returned)
        sv.sp("close", id=tab)

        tab = sv.sp("open", url=f"{base}/plain.html")["resultID"]
        sv.cmd({"do": "resize", "width": 1180, "height": 780, "steps": 2})
        time.sleep(1.5)
        sv.cmd({"do": "eval", "id": tab, "js": "scrollTo(0,1200)"})
        before = source_state(tab)
        native = sv.cmd({"do": "eval", "id": tab, "js": native_isolate, "world": "search"}).get("value")
        sv.cmd({"do": "eval", "id": tab, "js": "document.querySelector('video').pause()"})
        failed = sv.cmd({"do": "eval", "id": tab, "js": isolate, "world": "search"}).get("value")
        t.ok("paused retry: a prepared native video can stop before fitting is retried",
             isinstance(native, dict) and native.get("native") is True and failed == "none", failed)
        # Browser's failed retry explicitly restores the preceding preparation.
        sv.cmd({"do": "eval", "id": tab, "js": restore, "world": "search"})
        time.sleep(1.1)
        returned = source_state(tab)
        t.ok("paused retry: cleanup restores the source instead of leaving it isolated",
             same_source(before, returned) and not returned["playing"] and not returned["native"]
             and not returned["floating"] and not returned["marked"], returned)
        sv.sp("close", id=tab)

        rejected = ("video-clip", "video-mask", "video-minimum", "video-padding-border", "opacity", "plain", *ANCESTOR_CASES)
        for name in rejected:
            label = "partly-offscreen" if name == "plain" else name
            tab = sv.sp("open", url=f"{base}/{name}.html")["resultID"]
            sv.cmd({"do": "resize", "width": 1180, "height": 780, "steps": 2})
            time.sleep(1.5)
            sv.cmd({"do": "eval", "id": tab, "js": "scrollTo(0,1500)" if name == "plain" else "scrollTo(0,1200)"})
            if name in ANCESTOR_CASES:
                source = source_state(tab)
                x, y, width, height = source["box"]
                t.ok(f"{name}: the complete source box is inside the CSS viewport before preparation",
                     x >= 0 and y >= 0 and x + width <= source["page"][0]
                     and y + height <= source["page"][1], source)
            before = sv.cmd({"do": "eval", "id": tab, "js": styling})["value"]
            said = sv.cmd({"do": "eval", "id": tab, "js": native_isolate, "world": "search"}).get("value")
            p = json.loads(sv.cmd({"do": "eval", "id": tab, "js": PROBE})["value"])
            wide = abs(p["x"]) < 1 and abs(p["w"] - p["iw"]) < 1 and abs(2 * p["y"] + p["h"] - p["ih"]) < 2 and p["h"] <= p["ih"] + 1
            tall = abs(p["y"]) < 1 and abs(p["h"] - p["ih"]) < 1 and abs(2 * p["x"] + p["w"] - p["iw"]) < 2 and p["w"] <= p["iw"] + 1
            fallback = isinstance(said, dict) and said.get("floating") is True and said.get("native") is False
            t.ok(f"{label}: a native request falls back to a complete visible contain fit",
                 fallback and (wide or tall) and p["seen"] and p["playing"] and p["fit"] == "contain"
                 and p["clip"] == "none" and p["mask"] == "none" and not source_state(tab)["native"],
                 {"said": said, "probe": p})
            sv.cmd({"do": "eval", "id": tab, "js": restore, "world": "search"})
            time.sleep(1.1)
            after = sv.cmd({"do": "eval", "id": tab, "js": styling})["value"]
            t.ok(f"{label}: native-request fallback restores the player's styles", before == after, after)
            sv.sp("close", id=tab)

        # Back in its tab, Twitch's chat is open again, as it was when the
        # video went out: put back while the page is still the little
        # window's size, as land does, and the page then made larger.
        tab = sv.sp("open", url=f"{base}/twitch-chat.html")["resultID"]
        sv.cmd({"do": "resize", "width": 1180, "height": 780, "steps": 2})
        time.sleep(1.5)
        sv.cmd({"do": "eval", "id": tab, "js": isolate, "world": "search"})
        sv.cmd({"do": "resize", "width": 700, "height": 500, "steps": 2})
        shut = sv.cmd({"do": "eval", "id": tab, "js": CHAT_OPEN})["value"]
        sv.cmd({"do": "eval", "id": tab, "js": restore, "world": "search"})
        sv.cmd({"do": "resize", "width": 1180, "height": 780, "steps": 2})
        time.sleep(1.1)
        opened = sv.cmd({"do": "eval", "id": tab, "js": CHAT_OPEN})["value"]
        t.ok("twitch-chat: returning opens the chat folded away while floating", shut is False and opened is True, (shut, opened))
        sv.sp("close", id=tab)
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
