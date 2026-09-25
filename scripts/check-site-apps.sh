#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
RUNNER="$(mktemp -t search-site-app-check)"
trap 'rm -f "$RUNNER"' EXIT
swiftc Sources/Search/SiteAppBundle.swift Tests/SiteApps.swift -o "$RUNNER"
"$RUNNER"
