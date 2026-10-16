#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/search-address-regression.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM

swiftc \
  -swift-version 5 \
  "$repo_root/Sources/Search/Address.swift" \
  "$repo_root/Tests/AddressRegression/main.swift" \
  -o "$build_dir/address-regression"

"$build_dir/address-regression"
