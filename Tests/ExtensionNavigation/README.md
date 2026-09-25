# Extension return navigation

Run on macOS 15.4 or later, with Swift command-line tools, Python 3 and OpenSSL:

```sh
python3 Tests/ExtensionNavigation/run-tests.py
```

The runner uses the current macOS SDK. Set `SEARCH_TEST_SDK` to a different
SDK path when needed. It compiles the production policy and navigation
provenance helpers directly, without building the SwiftUI app.

The policy checks cover manifest versions 2 and 3, resource and origin
matching, malformed paths and unsupported declarations. The native WebKit
fixtures reproduce the failure without the handover, then verify callbacks
from committed HTTPS documents and still-blank tabs, redirect chains and
script navigation. They also check that an unlisted origin, a private
extension resource and an opaque navigation without a server redirect do
not trigger a handover. Successful callbacks must retain their query and
fragment and use exactly one replacement view.

The fixtures use a disposable extension, a nonpersistent WebKit data store,
synthetic callback values and a temporary HTTPS server bound to loopback.
Only the test delegate accepts the server's self-signed certificate. No
Search profile, real extension or account is accessed. Temporary files are
removed when the runner finishes.

These tests exercise native WebKit callbacks and the two production helpers;
the fixture supplies its own view replacement delegate. Also check real
NordPass sign-in in an isolated Search profile, then lock and unlock the
extension and use its keep-unlocked switch with the popup left open.
