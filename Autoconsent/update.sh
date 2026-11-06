#!/bin/bash
# DuckDuckGo's autoconsent (github.com/duckduckgo/autoconsent), as published
# on npm and unchanged: the script each page runs, built to be injected as
# it is (dist/autoconsent.playwright.js), the rules it reads
# (rules/compact-rules.json) and their licence, MPL-2.0. Search's side is
# Sources/Search/Autoconsent.swift.
#
#   ./Autoconsent/update.sh           the latest release
#   ./Autoconsent/update.sh 18.0.0    that one
set -euo pipefail
cd "$(dirname "$0")"
WANT="${1:-latest}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
(cd "$TMP" && npm pack --silent "@duckduckgo/autoconsent@$WANT" > /dev/null && tar xzf ./*.tgz)
cp "$TMP/package/dist/autoconsent.playwright.js" autoconsent.js
cp "$TMP/package/rules/compact-rules.json" rules.json
cp "$TMP/package/LICENSE" LICENSE
python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["version"])' "$TMP/package/package.json" > VERSION
echo "autoconsent $(cat VERSION)"
