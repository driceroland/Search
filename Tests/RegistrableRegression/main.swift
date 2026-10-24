import Foundation

// Registrable.sameSite, with macOS's own public-suffix test, as Passkeys
// uses it to let a frame of the page's own site ask for a passkey (#679).
let symbol = dlsym(dlopen("/System/Library/Frameworks/CFNetwork.framework/CFNetwork", RTLD_NOW), "_CFHostIsDomainTopLevel")
guard let symbol else { fatalError("no public-suffix test on this Mac") }
let test = unsafeBitCast(symbol, to: (@convention(c) (CFString) -> Bool).self)
let suffix: (String) -> Bool = { test($0 as CFString) }

var failures = 0
func expect(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("FAIL: \(what)") } else { print("ok    \(what)") }
}
expect(Registrable.sameSite("account.apple.com", "idmsa.apple.com", isSuffix: suffix), "Apple's sign-in frame is the page's own site")
expect(Registrable.sameSite("appleid.apple.com", "idmsa.apple.com", isSuffix: suffix), "…in Sign in with Apple too")
expect(Registrable.sameSite("example.com", "example.com", isSuffix: suffix), "the same host is the same site")
expect(!Registrable.sameSite("raindrop.io", "idmsa.apple.com", isSuffix: suffix), "another site is not")
expect(!Registrable.sameSite("evil.github.io", "victim.github.io", isSuffix: suffix), "two sites under a public suffix are not one")
expect(!Registrable.sameSite("a.co.uk", "b.co.uk", isSuffix: suffix), "nor under a two-label suffix")
expect(!Registrable.sameSite("10.0.0.1", "10.0.0.2", isSuffix: suffix), "addresses are never one site")
expect(!Registrable.sameSite("apple.com.evil.com", "idmsa.apple.com", isSuffix: suffix), "a look-alike is not")
expect(!Registrable.sameSite("a.example.com", "b.example.com", isSuffix: nil), "without the suffix test, only the same host")
if failures > 0 { exit(1) }
print("Registrable regressions passed.")
