#!/usr/bin/env python3
"""A few of DuckDuckGo's autoconsent rules, in the same compact form as the
whole set (rules/compact-rules.json in the npm package), for tests that
mustn't fetch it: AutoconsentTests and auto_consent.py.

    python3 -I Tests/AutoconsentFixtures/make.py compact-rules.json > Tests/AutoconsentFixtures/rules.json

Autoconsent/update.sh runs it with each new release. Kept: two rules for any
site (Complianz, Didomi), two for frames, and two for one site each, one of
them for its top page. Every string stays at its place, so a rule's
references still point where they did; the strings no kept rule uses are
left empty.
"""
import json
import sys

whole = json.load(open(sys.argv[1]))
rules, index = whole["r"], whole["index"]
by_name = {rule[1]: rule for rule in rules}
specific = rules[index["specificRuleRange"][0]:index["specificRuleRange"][1]]

generic = [by_name["Complianz banner"], by_name["didomi"]]
frames = [next(r for r in rules[slice(*index["frameRuleRange"])] if r[4] == 11),
          next(r for r in rules[slice(*index["frameRuleRange"])] if r[4] == 1 and not r[3])]
own = [next(r for r in specific if r[4] == 1 and r[3]),
       next(r for r in specific if r[4] == 22 and r[3].startswith("^https?://(www\\.)?"))]
# In the shipped order: those for any site, then those for one; the frames'
# range straddles the two, as it does in the whole set.
kept = generic + frames + own


def numbers(value, into):
    if isinstance(value, bool):
        return
    if isinstance(value, int):
        into.add(value)
    elif isinstance(value, list):
        for item in value: numbers(item, into)
    elif isinstance(value, dict):
        for item in value.values(): numbers(item, into)


used = set()
for rule in kept:
    numbers(rule[5:10], used)

json.dump({
    "v": whole["v"],
    "s": [text if i in used else "" for i, text in enumerate(whole["s"])],
    "r": kept,
    "index": {
        "genericRuleRange": [0, 4],
        "frameRuleRange": [2, 5],
        "specificRuleRange": [4, 6],
        "genericStringEnd": index["genericStringEnd"],
        "frameStringEnd": index["frameStringEnd"],
    },
}, sys.stdout, separators=(",", ":"))
