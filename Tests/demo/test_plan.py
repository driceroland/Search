#!/usr/bin/env python3
"""./demo's pure parts: easing, keys, script reading, layout, the pointer and
the camera. Nothing here starts an app: `python3 Tests/demo/test_plan.py`."""

import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools" / "demo"))
import plan  # noqa: E402


class Easing(unittest.TestCase):
    def test_ends(self):
        for f in (plan.EASE, plan.EASE_CAMERA):
            self.assertEqual(f(0), 0.0)
            self.assertEqual(f(1), 1.0)
            self.assertEqual(f(-1), 0.0)
            self.assertEqual(f(2), 1.0)

    def test_monotonic(self):
        for f in (plan.EASE, plan.EASE_CAMERA):
            values = [f(i / 200) for i in range(201)]
            self.assertTrue(all(b >= a - 1e-9 for a, b in zip(values, values[1:])))

    def test_matches_css_shape(self):
        # cubic-bezier(.16,1,.3,1) is far along early: ~0.75 at a quarter.
        self.assertGreater(plan.EASE(0.25), 0.7)
        self.assertLess(plan.EASE(0.25), 0.85)
        self.assertGreater(plan.EASE(0.5), 0.93)
        # ease-in-out is symmetric.
        self.assertAlmostEqual(plan.EASE_CAMERA(0.5), 0.5, places=4)
        self.assertAlmostEqual(plan.EASE_CAMERA(0.2) + plan.EASE_CAMERA(0.8), 1.0, places=4)

    def test_linear_bezier_is_linear(self):
        f = plan.bezier(1 / 3, 1 / 3, 2 / 3, 2 / 3)
        for t in (0.1, 0.37, 0.5, 0.9):
            self.assertAlmostEqual(f(t), t, places=4)


class Keys(unittest.TestCase):
    def test_combos(self):
        self.assertEqual(plan.parse_key("cmd+l"), (37, "l", ["cmd"]))
        self.assertEqual(plan.parse_key("cmd+shift+h"), (4, "H", ["cmd", "shift"]))
        self.assertEqual(plan.parse_key("ctrl+tab"), (48, "\t", ["ctrl"]))
        self.assertEqual(plan.parse_key("Escape"), (53, "\x1b", []))
        self.assertEqual(plan.parse_key("⌘+⇧+h"), (4, "H", ["cmd", "shift"]))

    def test_bad(self):
        for bad in ("", "cmd+", "hyper+a", "cmd+F13"):
            with self.assertRaises(ValueError):
                plan.parse_key(bad)


class Script(unittest.TestCase):
    def test_defaults(self):
        s = plan.parse({})
        self.assertEqual(s["window"], {"width": 1440, "height": 900})
        self.assertEqual(s["output"]["fps"], 60)
        self.assertEqual(s["steps"], [])

    def test_merges_nested(self):
        s = plan.parse({"output": {"width": 3840, "height": 2160}})
        self.assertEqual(s["output"]["fps"], 60)
        self.assertEqual(s["output"]["width"], 3840)

    def test_colour_names(self):
        s = plan.parse({"spaces": [{"name": "A", "colour": "Violet", "tabs": ["https://a.example"]}]})
        self.assertEqual(s["spaces"][0]["colour"], 5)
        self.assertEqual(s["spaces"][0]["tabs"][0], {"url": "https://a.example"})

    def test_errors(self):
        bad = [
            {"nope": 1},
            {"window": {"width": 100}},
            {"output": {"width": 1000, "height": 1000}},
            {"spaces": [{"colour": 1}]},
            {"spaces": [{"name": "A", "colour": "pink"}]},
            {"spaces": [{"name": "A", "tabs": [{"url": "ftp://x"}]}]},
            {"spaces": [{"name": "A", "tabs": [{"url": "https://a", "name": "x"}, {"url": "https://b", "name": "x"}]}]},
            {"steps": [{"do": "teleport"}]},
            {"steps": [{"do": "move"}]},
            {"steps": [{"do": "key", "key": "cmd+nope"}]},
            {"steps": [{"do": "wait", "at": 1, "wait": 2}]},
            {"steps": [{"do": "zoom", "rect": [1, 2]}]},
            {"steps": [{"do": "drag", "to": [1, 2]}]},
        ]
        for raw in bad:
            with self.assertRaises(ValueError, msg=raw):
                plan.parse(raw)

    def test_example_parses(self):
        s = plan.load(str(ROOT / "Tests" / "demo" / "example.json"))
        self.assertGreaterEqual(len(s["spaces"]), 2)
        self.assertTrue(s["steps"])

    def test_targets(self):
        self.assertEqual(plan.target([10, 20], (1440, 900)), (10.0, 20.0))
        self.assertEqual(plan.target("center", (1440, 900)), (720, 450))
        self.assertEqual(plan.target("25%, 50%", (1440, 900)), (360, 450))
        with self.assertRaises(ValueError):
            plan.target("somewhere", (1440, 900))


class Layout(unittest.TestCase):
    def test_centred_and_inside(self):
        (x, y, w, h), k, radius, shadows = plan.layout(1920, 1080, 1440, 900)
        self.assertAlmostEqual(x + w / 2, 960)
        self.assertAlmostEqual(y + h / 2, 540)
        self.assertAlmostEqual(w / h, 1440 / 900)
        self.assertLessEqual(h, 1080 * (1 - 2 * 0.07) + 1e-6)
        self.assertGreater(y, 0)
        self.assertAlmostEqual(radius, 16 * k)
        self.assertEqual(len(shadows), 2)

    def test_4k_doubles(self):
        a = plan.layout(1920, 1080, 1440, 900)
        b = plan.layout(3840, 2160, 1440, 900)
        # Twice the pixels a point, but never past the 2 recorded.
        self.assertAlmostEqual(b[1], min(2.0, 2 * a[1]))
        self.assertAlmostEqual(b[3][0]["blur"], 2 * a[3][0]["blur"])
        c = plan.layout(3840, 2160, 1600, 1000)
        self.assertAlmostEqual(c[1], 2 * plan.layout(1920, 1080, 1600, 1000)[1])

    def test_never_past_recorded_pixels(self):
        _, k, _, _ = plan.layout(3840, 2160, 800, 600, margin=0)
        self.assertLessEqual(k, 2.0)


class Pointer(unittest.TestCase):
    def test_move_eases_and_lands(self):
        events = [{"t": 1.0, "kind": "move", "to": [100, 0], "dur": 1.0}]
        track = plan.cursor_track(events, start=0.0, frames=180, fps=60, home=(0, 0))
        self.assertEqual(track[0][:2], [0, 0])
        self.assertEqual(track[60][:2], [0, 0])          # t = 1.0: not moved yet
        self.assertGreater(track[75][0], 50)              # a quarter in: well past half (ease-out)
        self.assertEqual(track[120][:2], [100, 0])        # t = 2.0: there
        self.assertEqual(track[179][:2], [100, 0])
        xs = [p[0] for p in track]
        self.assertTrue(all(b >= a for a, b in zip(xs, xs[1:])))

    def test_moves_chain_from_where_it_is(self):
        events = [{"t": 0.0, "kind": "move", "to": [100, 100], "dur": 0.5},
                  {"t": 1.0, "kind": "move", "to": [200, 100], "dur": 0.5}]
        track = plan.cursor_track(events, start=0.0, frames=120, fps=60, home=(0, 0))
        self.assertEqual(track[59][:2], [100, 100])
        self.assertEqual(track[119][:2], [200, 100])

    def test_press_scales_down_and_back(self):
        events = [{"t": 1.0, "kind": "down"}, {"t": 1.1, "kind": "up"}]
        track = plan.cursor_track(events, start=0.0, frames=120, fps=60, home=(5, 5))
        scales = [p[2] for p in track]
        self.assertEqual(scales[59], 1.0)
        self.assertAlmostEqual(min(scales), plan.PRESS_SCALE, places=3)
        self.assertEqual(scales[100], 1.0)

    def test_hide_and_show_fade(self):
        events = [{"t": 0.5, "kind": "hide"}, {"t": 1.5, "kind": "show"}]
        track = plan.cursor_track(events, start=0.0, frames=150, fps=60, home=(0, 0))
        self.assertEqual(track[0][3], 1.0)
        self.assertEqual(track[60][3], 0.0)
        self.assertEqual(track[149][3], 1.0)
        self.assertTrue(0 < track[33][3] < 1)

    def test_drag_points(self):
        pts = plan.drag_points((0, 0), (100, 50), 0.5)
        self.assertEqual(pts[0], [0, 0])
        self.assertEqual(pts[-1], [100, 50])
        self.assertEqual(len(pts), 31)


class Camera(unittest.TestCase):
    def test_target_fills_and_stays_inside(self):
        rect, k, _, _ = plan.layout(1920, 1080, 1440, 900)
        cx, cy, z = plan.camera_target([0, 0, 360, 225], rect, k, 1920, 1080)
        self.assertGreater(z, 1.5)
        self.assertGreaterEqual(cx - 1920 / (2 * z), -1e-6)
        self.assertGreaterEqual(cy - 1080 / (2 * z), -1e-6)
        self.assertEqual(plan.camera_target(None, rect, k, 1920, 1080), (960, 540, 1.0))
        # Never more than 2.5×, never less than 1×.
        self.assertLessEqual(plan.camera_target([0, 0, 1, 1], rect, k, 1920, 1080)[2], 2.5)
        self.assertEqual(plan.camera_target([0, 0, 1440, 900], rect, k, 1920, 1080)[2], 1.0)

    def test_track_eases_in_and_back(self):
        rect, k, _, _ = plan.layout(1920, 1080, 1440, 900)
        events = [{"t": 1.0, "rect": [100, 100, 400, 250], "dur": 1.0}, {"t": 3.0, "rect": None, "dur": 1.0}]
        track = plan.camera_track(events, 0.0, 300, 60, 1920, 1080, rect, k)
        self.assertEqual(track[0], [960, 540, 1])
        self.assertGreater(track[150][2], 1.5)
        self.assertEqual(track[299], [960, 540, 1])
        zs = [c[2] for c in track[60:121]]
        self.assertTrue(all(b >= a for a, b in zip(zs, zs[1:])))


if __name__ == "__main__":
    unittest.main(verbosity=1)
