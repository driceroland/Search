import Foundation

// Which scheme a typed address gets. Address.swift alone, so this runs
// without building the app (Tests/AddressRegression/run.sh).

private var failures = 0

private func expect(_ typed: String, _ wanted: String?) {
    let got = Address.url(from: typed)?.absoluteString
    guard got != wanted else { return }
    failures += 1
    fputs("FAIL: \(typed) became \(got ?? "nothing"), expected \(wanted ?? "nothing")\n", stderr)
}

// A server on this Mac or on the local network, which almost never has a
// certificate: plain http.
expect("localhost:3000", "http://localhost:3000")
expect("printer.local", "http://printer.local")
expect("127.0.0.1:8080", "http://127.0.0.1:8080")
expect("0.0.0.0:8080", "http://0.0.0.0:8080")
expect("10.0.0.1", "http://10.0.0.1")
expect("10.255.255.254:9000", "http://10.255.255.254:9000")
expect("192.168.1.1", "http://192.168.1.1")
expect("172.16.0.1", "http://172.16.0.1")
expect("172.31.255.254", "http://172.31.255.254")

// A website, whatever its name looks like: https.
expect("example.com", "https://example.com")
expect("172.15.0.1", "https://172.15.0.1")
expect("172.32.0.1", "https://172.32.0.1")
// 10.io, 10.ai and 10.org are registered domains, and a name whose first
// labels read as a private address is still a name.
expect("10.io", "https://10.io")
expect("10.org/about", "https://10.org/about")
expect("10.0.0.1.example.com", "https://10.0.0.1.example.com")
expect("192.168.1.1.example.com", "https://192.168.1.1.example.com")

// Not a place at all.
expect("hello world", nil)
expect("todo", nil)

if failures > 0 {
    fputs("\(failures) address assertion(s) failed.\n", stderr)
    exit(1)
}
print("Address scheme regressions passed.")
