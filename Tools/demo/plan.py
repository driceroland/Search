"""The thinking half of ./demo, kept free of the app so it can be tested:
reading a script, the pointer's path and presses, the camera, and where the
window sits in the frame. Tests/demo/test_plan.py runs it.

Coordinates: "window points" are the browser window's own points from its
top left (what bench verbs like `split mouse` take); "output pixels" are the
video's, from its top left.
"""

import json
import math
import re

# ---------------------------------------------------------------- easing

def bezier(x1, y1, x2, y2):
    """CSS cubic-bezier(x1, y1, x2, y2) as a function of 0…1."""
    def at(a1, a2, s):
        return 3 * a1 * s * (1 - s) ** 2 + 3 * a2 * s * s * (1 - s) + s ** 3

    def slope(a1, a2, s):
        return 3 * a1 * (1 - s) ** 2 + 6 * (a2 - a1) * s * (1 - s) + 3 * (1 - a2) * s * s

    def ease(t):
        if t <= 0: return 0.0
        if t >= 1: return 1.0
        s = t
        for _ in range(8):  # Newton
            d = slope(x1, x2, s)
            if abs(d) < 1e-6: break
            s -= (at(x1, x2, s) - t) / d
            s = min(1.0, max(0.0, s))
        if abs(at(x1, x2, s) - t) > 1e-5:  # bisection when Newton wanders
            lo, hi = 0.0, 1.0
            for _ in range(40):
                s = (lo + hi) / 2
                if at(x1, x2, s) < t: lo = s
                else: hi = s
        return at(y1, y2, s)
    return ease

# The pointer's moves: quick out, long gentle settle.
EASE = bezier(0.16, 1, 0.3, 1)
# The camera: slow in, slow out.
EASE_CAMERA = bezier(0.65, 0, 0.35, 1)

# ---------------------------------------------------------------- keys

KEYCODES = {
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
    "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
    "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
    "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
    ".": 47, "`": 50,
}
NAMED = {"return": (36, "\r"), "enter": (36, "\r"), "tab": (48, "\t"), "space": (49, " "), "delete": (51, "\x7f"),
         "escape": (53, "\x1b"), "esc": (53, "\x1b"), "left": (123, ""), "right": (124, ""),
         "down": (125, ""), "up": (126, "")}
MODS = {"cmd": "cmd", "command": "cmd", "⌘": "cmd", "shift": "shift", "⇧": "shift", "ctrl": "ctrl", "control": "ctrl",
        "⌃": "ctrl", "opt": "opt", "option": "opt", "alt": "opt", "⌥": "opt"}


def parse_key(combo):
    """"cmd+shift+h" → (key code, characters, [mods]) for bench's `press`."""
    parts = [p.strip().lower() for p in str(combo).split("+") if p.strip()]
    if not parts: raise ValueError(f"no key in {combo!r}")
    *mods, key = parts
    for m in mods:
        if m not in MODS: raise ValueError(f"unknown modifier {m!r} in {combo!r}")
    mods = sorted({MODS[m] for m in mods}, key=["cmd", "shift", "ctrl", "opt"].index)
    if key in NAMED: code, chars = NAMED[key]
    elif key in KEYCODES: code, chars = KEYCODES[key], key
    else: raise ValueError(f"unknown key {key!r} in {combo!r}")
    if "shift" in mods and len(chars) == 1 and chars.isalpha(): chars = chars.upper()
    return code, chars, mods

# ---------------------------------------------------------------- the script

COLOURS = ["none", "blue", "green", "orange", "red", "violet"]

DEFAULTS = {
    "window": {"width": 1440, "height": 900},
    "output": {"width": 1920, "height": 1080, "fps": 60, "margin": 0.07, "crf": 16, "prores": False,
               "radius": 16, "cursor": 1.0},
    "background": {"image": None, "blur": 0},
    "settings": {},
    "spaces": [],
    "lead": 1.0,
    "tail": 1.5,
    "settle": 3.0,
    "steps": [],
}

ACTIONS = {
    "wait", "move", "click", "drag", "cursor", "key", "type", "field", "suggest", "space", "split", "select",
    "peek", "pinch", "hover", "menu", "style", "zoom", "scroll", "eval", "bench", "tap", "release",
}


def load(path):
    """A script file: JSON, or YAML when PyYAML happens to be installed."""
    with open(path, encoding="utf-8") as f:
        text = f.read()
    if path.endswith((".yaml", ".yml")):
        try:
            import yaml  # noqa: optional
        except ImportError:
            raise SystemExit("YAML scripts need PyYAML (pip install pyyaml), or write the script as JSON")
        return parse(yaml.safe_load(text))
    return parse(json.loads(text))


def parse(raw):
    """The script with every default filled in, or ValueError saying where it is wrong."""
    if not isinstance(raw, dict): raise ValueError("a script is an object")
    unknown = set(raw) - set(DEFAULTS) - {"title", "look", "start", "world", "comment"}
    if unknown: raise ValueError(f"unknown top-level keys: {sorted(unknown)}")
    s = json.loads(json.dumps(DEFAULTS))
    for key, value in raw.items():
        if isinstance(s.get(key), dict) and isinstance(value, dict): s[key].update(value)
        else: s[key] = value
    w, o = s["window"], s["output"]
    for k in ("width", "height"):
        if not (isinstance(w[k], (int, float)) and 640 <= w[k] <= 3000): raise ValueError(f"window.{k} must be 640…3000")
    if (o["width"], o["height"]) not in ((1920, 1080), (3840, 2160), (2560, 1440), (1280, 720)):
        raise ValueError("output is 1920×1080, 2560×1440, 3840×2160 or 1280×720")
    if o["fps"] not in (24, 25, 30, 50, 60): raise ValueError("output.fps is 24, 25, 30, 50 or 60")
    if not isinstance(s["settings"], dict): raise ValueError("settings is an object of defaults keys and values")
    names = set()
    for i, space in enumerate(s["spaces"]):
        where = f"spaces[{i}]"
        if not isinstance(space, dict) or not space.get("name"): raise ValueError(f"{where} needs a name")
        colour = space.get("colour", 0)
        if isinstance(colour, str):
            if colour.lower() not in COLOURS: raise ValueError(f"{where}.colour is one of {COLOURS}")
            space["colour"] = COLOURS.index(colour.lower())
        elif not (isinstance(colour, int) and 0 <= colour < len(COLOURS)): raise ValueError(f"{where}.colour is 0…5 or a name")
        for kind in ("tabs", "pins"):
            for j, tab in enumerate(space.get(kind, [])):
                if isinstance(tab, str): tab = space[kind][j] = {"url": tab}
                if not re.match(r"^(https?|file|about|search|local):", tab.get("url", "")):
                    raise ValueError(f"{where}.{kind}[{j}] needs a url (https://…)")
                if tab.get("name"):
                    if tab["name"] in names: raise ValueError(f"two tabs are named {tab['name']!r}")
                    names.add(tab["name"])
        for j, folder in enumerate(space.get("folders", [])):
            if not folder.get("name"): raise ValueError(f"{where}.folders[{j}] needs a name")
            for k, pin in enumerate(folder.get("pins", [])):
                if isinstance(pin, str): folder["pins"][k] = {"url": pin}
    for i, step in enumerate(s["steps"]):
        where = f"steps[{i}]"
        if not isinstance(step, dict): raise ValueError(f"{where} is an object")
        do = step.get("do", "wait")
        if do not in ACTIONS: raise ValueError(f"{where}: unknown action {do!r} (one of {sorted(ACTIONS)})")
        step["do"] = do
        if "at" in step and "wait" in step: raise ValueError(f"{where}: give at or wait, not both")
        for k in ("at", "wait", "dur"):
            if k in step and not (isinstance(step[k], (int, float)) and step[k] >= 0): raise ValueError(f"{where}.{k} is seconds ≥ 0")
        if do == "key": parse_key(step.get("key", ""))
        if do in ("move", "drag") and "to" not in step: raise ValueError(f"{where}: {do} needs to")
        if do == "drag" and "from" not in step: raise ValueError(f"{where}: drag needs from")
        if do == "type" and not isinstance(step.get("text"), str): raise ValueError(f"{where}: type needs text")
        if do == "zoom" and not (step.get("rect") is None or step.get("rect") == "reset"
                                 or (isinstance(step.get("rect"), list) and len(step["rect"]) == 4)):
            raise ValueError(f"{where}: zoom takes rect [x, y, w, h] in window points, or \"reset\"")
    return s


def target(spec, window):
    """A point in window points: [x, y]; "50%,40%" of the window; or
    "center". "page:SELECTOR" is resolved by the runner, which can ask the page."""
    w, h = window
    if isinstance(spec, (list, tuple)) and len(spec) == 2: return float(spec[0]), float(spec[1])
    if spec == "center": return w / 2, h / 2
    m = re.match(r"^\s*([\d.]+)%\s*,\s*([\d.]+)%\s*$", str(spec))
    if m: return w * float(m.group(1)) / 100, h * float(m.group(2)) / 100
    raise ValueError(f"not a point: {spec!r}")

# ---------------------------------------------------------------- the frame

def layout(out_w, out_h, win_w, win_h, margin=0.07, radius_pt=16):
    """Where the window goes in the frame: centred, as large as fits with
    `margin` of the frame's height free above and below (and as much at the
    sides), never upscaled past 2 output pixels a point. Returns the rect
    (x, y, w, h) in output pixels, pixels per point, the corner radius and
    the shadows, all in output pixels."""
    room_w = out_w * (1 - 2 * margin * out_h / out_w)
    room_h = out_h * (1 - 2 * margin)
    k = min(room_w / win_w, room_h / win_h, 2.0)  # never past the 2 pixels a point recorded
    w, h = win_w * k, win_h * k
    x, y = (out_w - w) / 2, (out_h - h) / 2
    s = out_h / 1080
    shadows = [  # a wide soft one, as macOS draws an active window's, and a close contact one
        {"blur": 70 * s, "y": 28 * s, "alpha": 0.45},
        {"blur": 10 * s, "y": 3 * s, "alpha": 0.30},
    ]
    return (x, y, w, h), k, radius_pt * k, shadows

# ---------------------------------------------------------------- the pointer

PRESS_DOWN = 0.07   # seconds into a press to its smallest
PRESS_UP = 0.16     # seconds back to full size after letting go
PRESS_SCALE = 0.82
FADE = 0.18


def cursor_track(events, start, frames, fps, home):
    """The pointer in every frame: [x, y, scale, opacity] in window points.

    events (wall-clock times, in order): {"t", "kind": "move", "to", "dur"};
    {"t", "kind": "down"} / {"t", "kind": "up"}; {"t", "kind": "show"|"hide"};
    {"t", "kind": "jump", "to"}. home: where it starts."""
    moves, presses, shows = [], [], [(start - 10, True)]
    pos = tuple(home)
    for e in sorted(events, key=lambda e: e["t"]):
        k = e["kind"]
        if k == "move":
            moves.append((e["t"], max(1e-3, e.get("dur", 0.6)), tuple(e["to"])))
        elif k == "jump":
            moves.append((e["t"], 1e-3, tuple(e["to"])))
        elif k == "down":
            presses.append([e["t"], None])
        elif k == "up":
            for p in reversed(presses):
                if p[1] is None: p[1] = e["t"]; break
        elif k in ("show", "hide"):
            shows.append((e["t"], k == "show"))

    def where(t):
        p = pos
        for t0, dur, to in moves:
            if t < t0: break
            f = EASE((t - t0) / dur)
            p = (p[0] + (to[0] - p[0]) * f, p[1] + (to[1] - p[1]) * f) if f < 1 else to
        return p

    def scale(t):
        k = 1.0
        for down, up in presses:
            up = up if up is not None else down + PRESS_DOWN
            if t < down: continue
            if t <= up:
                k = min(k, 1 - (1 - PRESS_SCALE) * min(1, (t - down) / PRESS_DOWN))
            elif t < up + PRESS_UP:
                deepest = 1 - (1 - PRESS_SCALE) * min(1, (up - down) / PRESS_DOWN)
                k = min(k, deepest + (1 - deepest) * EASE((t - up) / PRESS_UP))
        return k

    def opacity(t):
        a, last = 1.0, None
        for t0, on in shows:
            if t < t0: break
            last = (t0, on)
        if last is None: return 1.0
        t0, on = last
        f = min(1, (t - t0) / FADE)
        return f if on else 1 - f

    out = []
    for i in range(frames):
        t = start + i / fps
        x, y = where(t)
        out.append([round(x, 3), round(y, 3), round(scale(t), 4), round(opacity(t), 4)])
    return out

# ---------------------------------------------------------------- the camera

def camera_target(rect_pt, window_rect, k, out_w, out_h, fill=0.85, most=2.5):
    """Centre and zoom for a rect of the window (points) to fill `fill` of
    the frame, kept inside the frame."""
    if rect_pt is None: return (out_w / 2, out_h / 2, 1.0)
    x, y, w, h = rect_pt
    px, py = window_rect[0] + x * k, window_rect[1] + y * k
    pw, ph = max(1, w * k), max(1, h * k)
    z = max(1.0, min(most, fill * min(out_w / pw, out_h / ph)))
    cx, cy = px + pw / 2, py + ph / 2
    half_w, half_h = out_w / (2 * z), out_h / (2 * z)
    cx = min(max(cx, half_w), out_w - half_w)
    cy = min(max(cy, half_h), out_h - half_h)
    return (cx, cy, z)


def camera_track(events, start, frames, fps, out_w, out_h, window_rect, k):
    """[cx, cy, zoom] per frame. events: {"t", "rect" (window points or None), "dur"}."""
    rest = (out_w / 2, out_h / 2, 1.0)
    shots = []
    for e in sorted(events, key=lambda e: e["t"]):
        shots.append((e["t"], max(1e-3, e.get("dur", 0.9)),
                      camera_target(e.get("rect"), window_rect, k, out_w, out_h)))
    out = []
    for i in range(frames):
        t = start + i / fps
        c = rest
        for t0, dur, to in shots:
            if t < t0: break
            f = EASE_CAMERA((t - t0) / dur)
            # Zoom eased in log space so it feels even; centre follows.
            z = math.exp(math.log(c[2]) + (math.log(to[2]) - math.log(c[2])) * f)
            c = (c[0] + (to[0] - c[0]) * f, c[1] + (to[1] - c[1]) * f, z) if f < 1 else to
        out.append([round(c[0], 2), round(c[1], 2), round(c[2], 5)])
    return out


def drag_points(a, b, dur, fps=60):
    """The points a drag passes through, a frame apart, on the pointer's own easing."""
    n = max(2, int(round(dur * fps)))
    return [[a[0] + (b[0] - a[0]) * EASE(i / n), a[1] + (b[1] - a[1]) * EASE(i / n)] for i in range(n + 1)]
