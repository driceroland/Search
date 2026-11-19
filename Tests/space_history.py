#!/usr/bin/env python3
"""A space signed out of the others keeps its own history (#758).

Build first (`./build.sh`), then `python3 Tests/space_history.py`. A probe
with spaces on gets a space signed in with the first one and two signed out
of it. A page is visited in the first space and in each signed-out one,
through real tabs (a bench tab's visits never enter history), and each
space's history and address suggestions are read back: a signed-out
space's pages stay in it, across a relaunch, and its file goes when the
space is deleted. Clear… then empties one space's history, as Safari
clears one profile's, or every space's. No window is made or shown.
"""
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("space-history")


def space(**request):
    return sv.cmd({"do": "space", **request})


def go(index):
    space(action="go", index=index)
    time.sleep(0.5)


def history(typed=""):
    return sv.cmd({"do": "profile", "action": "history", "typed": typed})


def has(name, typed=""):
    """Whether the space on screen's history holds the page, and whether
    the field offers it for what is typed."""
    h = history(typed)
    return (any(u.endswith(f"/{name}") for u in h["history"]),
            any(u.endswith(f"/{name}") for u in h["offers"]))


def visit(name):
    sv.page(name)
    for _ in range(50):
        if has(name)[0]: return True
        time.sleep(0.1)
    return False


def file(space_id):
    return f"{sv.SUPPORT}/history-space-{space_id}.json"


def main():
    t = sv.T()
    try:
        sv.setup(spaces=True)
        sv.launch()
        space(action="new", name="Shared")
        space(action="new", name="Apart", fresh=True)
        space(action="new", name="Other", fresh=True)
        time.sleep(0.6)
        ids = {s["name"]: s["id"] for s in space()["spaces"]}
        t.ok("four spaces, two signed out", list(ids) == ["Personal", "Shared", "Apart", "Other"], ids)

        go(1)
        t.ok("a visit in the first space is in its history", visit("home-page"))
        go(3)
        t.ok("a visit in a signed-out space is in its history", visit("apart-secret"))
        go(4)
        t.ok("a visit in another signed-out space is in its history", visit("other-secret"))

        go(1)
        t.ok("the first space: none of the signed-out spaces' pages",
             not has("apart-secret")[0] and not has("other-secret")[0], history()["history"])
        t.ok("…and the field doesn't offer them", not has("apart-secret", "apart")[1], history("apart")["offers"])
        go(2)
        t.ok("a space signed in with the first shares its history", has("home-page")[0], history()["history"])
        t.ok("…but not the signed-out spaces'", not has("apart-secret")[0], history()["history"])
        go(3)
        t.ok("a signed-out space: its own page, no other space's",
             has("apart-secret")[0] and not has("home-page")[0] and not has("other-secret")[0], history()["history"])
        t.ok("…and the field offers its own page", has("apart-secret", "apart")[1], history("apart")["offers"])
        go(4)
        t.ok("the other signed-out space keeps apart from it too",
             has("other-secret")[0] and not has("apart-secret")[0], history()["history"])

        # Written to their own files, and read back after ⌘Q.
        sv.quit()
        time.sleep(1)
        t.ok("each signed-out space has a history file of its own",
             os.path.exists(file(ids["Apart"])) and os.path.exists(file(ids["Other"])))
        sv.launch()
        time.sleep(1)
        go(3)
        t.ok("after a relaunch the signed-out space still has its page", has("apart-secret")[0], history()["history"])
        go(1)
        t.ok("…and the first space still hasn't", not has("apart-secret")[0] and has("home-page")[0], history()["history"])

        # Deleting a signed-out space takes its history with it.
        go(3)
        space(action="delete")
        time.sleep(1)
        t.ok("a deleted signed-out space's history file goes with it", not os.path.exists(file(ids["Apart"])))
        t.ok("the other one's stays", os.path.exists(file(ids["Other"])))

        # Clear…, as Safari's choice of profile: every space's history, or one.
        scopes = sv.cmd({"do": "history", "scopes": True})["scopes"]
        t.ok("Clear… offers the shared history, named for its spaces, then the signed-out one",
             [s["name"] for s in scopes] == ["Personal, Shared", "Other"], scopes)
        sv.cmd({"do": "history", "clear": ids["Other"]})
        go(3)
        t.ok("clearing one signed-out space's history empties it", not has("other-secret")[0], history()["history"])
        go(1)
        t.ok("…and leaves the others' alone", has("home-page")[0], history()["history"])
        go(3)
        visit("other-again")
        sv.cmd({"do": "history", "clear": "all"})
        t.ok("All Spaces clears the signed-out space", not has("other-again")[0], history()["history"])
        go(1)
        t.ok("…and the first space", not has("home-page")[0], history()["history"])
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
