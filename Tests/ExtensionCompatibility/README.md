# Extension compatibility regression

Requires macOS 15.4 or later. Run `python3 Tests/ExtensionCompatibility/run.py`
after building Search. The runner copies the existing `build/Search.app` to a
temporary path, gives that copy its own bundle ID, signs it locally, and starts
it hidden with a random `SEARCH_PROBE` world. It installs only the fixture
extension and drives it through `./bench`; it never opens a website or calls
`navigator.credentials`.
For the smaller canonical relay-key unit check, run
`node Tests/ExtensionRelayKey/relay-key.test.mjs`.

The MV3 fixture exercises an extension page opening and reopening a popup,
`windows.getCurrent`, promise and callback `windows.update` geometry, the
background worker's `windows.onRemoved` event, and `getAll` cleanup. It also
relays two identical, synthetic Bitwarden-style `PickCredentialRequest`
messages per popup and checks the matching `PickCredentialResponse` messages.
This is a protocol-level fixture; it does not invoke WebAuthn or complete a
GitHub credential login. Page, popup, and worker
contexts check `Symbol.dispose` and `Symbol.asyncDispose` and call both resource
disposal methods. Each run saves a full JSON report, including sender metadata
and raw message JSON, to a unique file under the system temporary directory.

The runner quits only the named world through `./bench` and deletes only its
own profile and temporary app copy. It does not search for or signal other
Search processes.
