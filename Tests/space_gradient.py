#!/usr/bin/env python3
"""A space's gradient (SpaceGradient.swift), in a hidden probe.

Build first (`./build.sh debug`), then `python3 Tests/space_gradient.py`. It
uses the split suite's harness: started hidden in a world of its own, nothing
shown, everything removed afterwards. Through the bench's `space` verb (its
`pick` is a choice in the Colour… picker, its `picker` what the picker rings
and its preview says): a
gradient set on one space washes the chrome only while that space is on
screen, follows ⌃-switches and swipes, is kept beside the space's colour in
spaces.json (a space without one is written as before), comes back after a
relaunch, and goes when removed or when a plain colour is picked. A
gradient spaces.json can't read costs the space its gradient, never the
list. Its strength (Subtle, Rich, Vivid) is kept the same way, and one
that doesn't read is Subtle. The editor itself is a popover and is never opened here: how it looks
is checked off screen (see SpaceGradientTests).
"""
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("space-gradient")

t = sv.T()
DUSK = ["#8C8DF5", "#C779C4", "#D88B45"]


def space(**f):
    time.sleep(0.3)
    return sv.cmd({"do": "space", **f})


def saved():
    return {s["name"]: s for s in json.load(open(f"{sv.SUPPORT}/spaces.json"))}


def menu(st):
    return [i["title"] for i in st["menu"]]


def ringed(st):
    return (st["picker"]["kind"], st["picker"]["ringed"], st["picker"]["preview"])


def main():
    try:
        sv.setup(**{"spaces": True, "sidebar": True}); sv.launch()
        st = space()
        t.ok("one space, no wash", st["wash"] == "" and st["gradient"] == "", st)
        t.ok("one Colour… item in the space's menu, no submenu", "Colour…" in menu(st) and "Colour" not in menu(st) and "Gradient…" not in menu(st), menu(st))
        t.ok("picker: None ringed, the preview says no colour", ringed(st) == ("none", "None", "No colour"), st["picker"])
        t.ok("picker: None and five colours, six ready-made gradients",
             st["picker"]["colours"] == ["None", "Blue", "Green", "Orange", "Red", "Violet"] and len(st["picker"]["presets"]) == 6, st["picker"])
        space(action="new", name="Two"); time.sleep(0.8)
        space(action="colour", colour=1)
        st = space(action="gradient", colours=DUSK, angle=90.0, grain=True)
        t.ok("Two on screen with a gradient: washed with it", st["current"] == "Two" and st["wash"] == "Gradient", st["wash"])
        g = st["gradient"]
        t.ok("three colours, its angle and grain, drawn as 24 stops", len(g["colours"]) == 3 and g["angle"] == 90 and g["grain"] and g["stops"] == 24, g)
        t.ok("picker: a gradient of its own, nothing in the rows ringed", ringed(st) == ("custom", "", "Custom gradient"), st["picker"])

        disk = saved()
        t.ok("spaces.json: kept beside the colour", disk["Two"].get("gradient", {}).get("colours") == DUSK and disk["Two"]["colour"] == 1, disk["Two"])
        t.ok("spaces.json: a space without one is written as before", "gradient" not in disk["Personal"], disk["Personal"])

        st = space(action="go", index=1)
        t.ok("⌃1: Personal, no wash", st["current"] == "Personal" and st["wash"] == "", st["wash"])
        st = space(action="go", index=2)
        t.ok("⌃2: the gradient again", st["current"] == "Two" and st["wash"] == "Gradient", st["wash"])
        space(action="swipe", dx=160); time.sleep(0.8)
        st = space()
        t.ok("swiped back to Personal: no wash", st["current"] == "Personal" and st["wash"] == "", (st["current"], st["wash"]))
        space(action="swipe", dx=-160); time.sleep(0.8)
        st = space()
        t.ok("swiped on to Two: the gradient", st["current"] == "Two" and st["wash"] == "Gradient", (st["current"], st["wash"]))
        # Mid-swipe the wash is still the space on screen's; nothing switched yet.
        space(action="hold", dx=40); st = space()
        t.ok("held mid-swipe: still Two's gradient", st["current"] == "Two" and st["wash"] == "Gradient", st["wash"])
        space(action="release"); time.sleep(0.8)
        st = space(action="go", index=2)
        t.ok("let go, and back on Two", st["current"] == "Two" and not st["making"], (st["current"], st["making"]))

        st = space(action="gradient")
        t.ok("removed: back to its colour", st["wash"] == "Blue" and st["gradient"] == "", st["wash"])
        t.ok("picker: Blue ringed again", ringed(st) == ("colour", "Blue", "Blue"), st["picker"])
        t.ok("spaces.json: the gradient gone, the colour kept", "gradient" not in saved()["Two"] and saved()["Two"]["colour"] == 1, saved()["Two"])

        space(action="gradient", colours=DUSK[:2])
        st = space(action="colour", colour=3)
        t.ok("a colour picked replaces the gradient", st["wash"] == "Orange" and "gradient" not in saved()["Two"], st["wash"])
        st = space(action="gradient", colours=["#4285F5"])
        t.ok("one colour is no gradient", st["wash"] == "Orange", st["wash"])

        # The picker's choices, as its swatches make them.
        st = space(action="pick", choice="Dusk")
        t.ok("a ready-made gradient: washed with it, ringed", st["wash"] == "Gradient" and ringed(st) == ("gradient", "Dusk", "Dusk"), st["picker"])
        st = space(action="pick", choice="Green")
        t.ok("a colour: the gradient goes", st["wash"] == "Green" and "gradient" not in saved()["Two"], st["wash"])
        st = space(action="pick", choice="Custom")
        t.ok("Custom from a colour: a first gradient of its own", st["wash"] == "Gradient" and st["picker"]["kind"] == "custom", st["picker"])
        st = space(action="pick", choice="None")
        t.ok("None: no wash, nothing kept", st["wash"] == "" and ringed(st)[0] == "none" and saved()["Two"]["colour"] == 0, st["wash"])
        st = space(action="restore", colour=3, colours=DUSK)
        t.ok("Escape: what it had back", st["wash"] == "Gradient" and saved()["Two"]["colour"] == 3, (st["wash"], saved()["Two"]))
        space(action="restore", colour=3)

        # Strength: Subtle (as before), Rich or Vivid, for a colour and a
        # gradient alike, kept per space beside its look.
        st = space()
        t.ok("strength: Subtle, unwritten", st["strength"] == "subtle" and st["picker"]["strength"] == "Subtle"
             and st["picker"]["strengths"] == ["Subtle", "Rich", "Vivid"] and "strength" not in saved()["Two"], (st["strength"], saved()["Two"]))
        st = space(action="strength", strength="vivid")
        t.ok("Vivid on a colour: washed stronger, toned", st["strength"] == "vivid" and st["toned"]["light"]["opacity"] > 0.25
             and st["toned"]["dark"]["opacity"] > 0.35 and len(st["toned"]["light"]["colours"]) == 1, st["toned"])
        t.ok("spaces.json: vivid kept beside the colour", saved()["Two"].get("strength") == "vivid" and saved()["Two"]["colour"] == 3, saved()["Two"])
        st = space(action="pick", choice="Dusk")
        t.ok("a gradient picked keeps the strength", st["wash"] == "Gradient" and st["strength"] == "vivid" and len(st["toned"]["dark"]["colours"]) == 3, st["toned"])
        st = space(action="go", index=1)
        t.ok("⌃1: Personal, no wash, Subtle", st["wash"] == "" and st["strength"] == "subtle", (st["wash"], st["strength"]))
        st = space(action="go", index=2)
        t.ok("⌃2: Vivid again", st["strength"] == "vivid", st["strength"])
        st = space(action="strength", strength="rich")
        t.ok("Rich", st["strength"] == "rich" and saved()["Two"].get("strength") == "rich", saved()["Two"])
        try:
            space(action="strength", strength="loud"); refused = False
        except RuntimeError:
            refused = True
        t.ok("a strength there isn't: refused, Rich kept", refused and space()["strength"] == "rich", refused)
        st = space(action="restore", colour=3, strength="vivid")
        t.ok("Escape: the strength it had back", st["strength"] == "vivid" and st["wash"] == "Orange", (st["strength"], st["wash"]))
        space(action="strength", strength="subtle")
        t.ok("Subtle again: unwritten", "strength" not in saved()["Two"], saved()["Two"])
        space(action="strength", strength="vivid")

        # Kept across a relaunch.
        space(action="gradient", colours=DUSK, angle=180.0)
        sv.quit(); time.sleep(0.5); sv.launch()
        space(action="go", index=2); st = space()
        t.ok("relaunched: Two still has its gradient", st["current"] == "Two" and st["wash"] == "Gradient" and st["gradient"]["angle"] == 180, st["gradient"])
        t.ok("relaunched: and its strength", st["strength"] == "vivid", st["strength"])

        # A gradient that doesn't read: the list survives, the colour stands.
        sv.quit(); time.sleep(0.5)
        spaces = json.load(open(f"{sv.SUPPORT}/spaces.json"))
        for s in spaces:
            if s["name"] == "Two": s["gradient"] = {"colours": "not a list", "angle": "wide"}; s["strength"] = 7
        json.dump(spaces, open(f"{sv.SUPPORT}/spaces.json", "w"))
        sv.launch()
        space(action="go", index=2); st = space()
        t.ok("damaged strength: Subtle", st["strength"] == "subtle", st["strength"])
        t.ok("damaged gradient: both spaces there, Two washed with its colour",
             [s["name"] for s in st["spaces"]] == ["Personal", "Two"] and st["current"] == "Two" and st["wash"] == "Orange", (st["spaces"], st["wash"]))
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
