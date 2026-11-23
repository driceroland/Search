#!/usr/bin/env python3
"""Run every Swift test with independent native WebKit test sessions."""
import os
import re
import subprocess
import sys

suite = "DownloadLifecycleTests"
devtools = r"^SearchTests\.Developer"
# DevTools uses hidden WebKit inspector windows. Run those tests in their
# own process so the browser suites start with their usual AppKit state.
result = subprocess.run(["swift", "test", "--skip", f"{suite}|{devtools}"])
failed = result.returncode != 0
print("Isolated DevTools suites", flush=True)
env = dict(os.environ, SEARCH_PROBE=f"ci-devtools-{os.getpid()}")
result = subprocess.run(["swift", "test", "--skip-build", "--filter", devtools], env=env)
failed |= result.returncode != 0

# Native WebKit state is never reused by two download journeys.
listing = subprocess.run(["swift", "test", "list"], check=True, capture_output=True, text=True)
cases = [line.strip() for line in listing.stdout.splitlines()
         if re.fullmatch(r"SearchTests\.DownloadLifecycleTests/test\w+", line.strip())]
if not cases:
    raise RuntimeError(f"Expected WebKit download cases; discovered none in {suite}")
for index, case in enumerate(cases):
    print(f"Isolated WebKit case: {case}", flush=True)
    env = dict(os.environ, SEARCH_PROBE=f"ci-download-{os.getpid()}-{index}")
    result = subprocess.run(["swift", "test", "--skip-build", "--filter", f"^{re.escape(case)}$"], env=env)
    failed |= result.returncode != 0
sys.exit(1 if failed else 0)
