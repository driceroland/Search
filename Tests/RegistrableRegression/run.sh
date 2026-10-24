#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
out=$(mktemp -d "${TMPDIR:-/tmp}/search-registrable.XXXXXX")
trap 'rm -rf "$out"' EXIT HUP INT TERM
swiftc -swift-version 5 "$repo_root/Sources/Search/Registrable.swift" "$repo_root/Tests/RegistrableRegression/main.swift" -o "$out/registrable"
"$out/registrable"
