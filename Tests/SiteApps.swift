import Foundation

@main
enum SiteAppsCheck {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-site-app-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw CheckFailure.failed(message) }
        }
        func rejected(_ raw: String) -> Bool {
            guard let url = URL(string: raw) else { return true }
            return !SiteAppBundle.accepts(url)
        }
        func command(_ executable: String, _ arguments: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }

        for url in ["file:///etc/passwd", "javascript:alert(1)", "ftp://example.com/",
                    "https:///missing-host", "https://user:secret@example.com/"] {
            try check(rejected(url), "unsupported address was accepted: \(url)")
        }
        try check(SiteAppBundle.accepts(URL(string: "https://news.ycombinator.com/")!), "valid HTTPS rejected")
        let sanitized = try SiteAppBundle.name(from: "../$(touch pwned)/\nHacker News.app")
        try check(sanitized == "-$(touch pwned)--Hacker News",
                  "title was not safely reduced to a display name")
        let longName = try SiteAppBundle.name(from: String(repeating: "界", count: 300))
        try check(longName.utf8.count <= 180,
                  "long Unicode title exceeds the filename budget")
        do {
            _ = try SiteAppBundle.name(from: "../... ///")
            throw CheckFailure.failed("punctuation-only title was accepted")
        } catch SiteAppBundle.Failure.name { }

        let helper = URL(fileURLWithPath: "/usr/bin/true") // copied and signed, never launched
        let browser = Bundle.main
        let apps = root.appendingPathComponent("Applications", isDirectory: true)
        let hostileTitle = "Hacker $(touch SHOULD_NOT_EXIST) & <News>"
        let page = URL(string: "https://news.ycombinator.com/?q=%3Ctag%3E&x=1")!
        let first = try SiteAppBundle.create(name: hostileTitle, url: page, in: apps,
                                             helper: helper, browser: browser, icon: nil)
        let second = try SiteAppBundle.create(name: hostileTitle, url: page, in: apps,
                                              helper: helper, browser: browser, icon: nil)
        try check(first.lastPathComponent == "Hacker $(touch SHOULD_NOT_EXIST) & <News>.app",
                  "safe punctuation was unexpectedly lost from the app filename")
        try check(second.lastPathComponent == "Hacker $(touch SHOULD_NOT_EXIST) & <News> 2.app",
                  "collision did not choose a unique app name")
        try check(FileManager.default.fileExists(atPath: first.path) && FileManager.default.fileExists(atPath: second.path),
                  "created app bundle is missing")
        let signatureStatus = try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", first.path])
        try check(signatureStatus == 0,
                  "generated app signature does not verify")

        let firstPlistURL = first.appendingPathComponent("Contents/Info.plist")
        let firstPlistData = try Data(contentsOf: firstPlistURL)
        let plist = try PropertyListSerialization.propertyList(from: firstPlistData, format: nil) as! [String: Any]
        try check(plist["SearchSiteURL"] as? String == page.absoluteString, "URL did not survive plist serialization")
        try check(plist["CFBundleDisplayName"] as? String == hostileTitle, "display name did not survive plist serialization")
        try check(plist["CFBundlePackageType"] as? String == "APPL", "app package metadata is invalid")
        let firstID = plist["CFBundleIdentifier"] as? String
        let secondData = try Data(contentsOf: second.appendingPathComponent("Contents/Info.plist"))
        let secondPlist = try PropertyListSerialization.propertyList(from: secondData, format: nil) as! [String: Any]
        try check(firstID != nil && firstID != (secondPlist["CFBundleIdentifier"] as? String),
                  "bundle IDs are not unique")
        try check(!FileManager.default.fileExists(atPath: apps.appendingPathComponent("SHOULD_NOT_EXIST").path),
                  "hostile name executed as a shell command")

        let existing = apps.appendingPathComponent("Hacker $(touch SHOULD_NOT_EXIST) & <News> 3.app")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let sentinel = existing.appendingPathComponent("keep.txt")
        try Data("keep me".utf8).write(to: sentinel)
        let third = try SiteAppBundle.create(name: hostileTitle, url: page, in: apps,
                                             helper: helper, browser: browser, icon: nil)
        try check(third.lastPathComponent.hasSuffix(" 4.app"), "existing destination was overwritten")
        let sentinelValue = try Data(contentsOf: sentinel)
        try check(String(decoding: sentinelValue, as: UTF8.self) == "keep me",
                  "pre-existing bundle contents changed")

        let badApps = root.appendingPathComponent("missing-helper-target", isDirectory: true)
        do {
            _ = try SiteAppBundle.create(name: "No helper", url: page, in: badApps,
                                         helper: root.appendingPathComponent("absent"), browser: browser, icon: nil)
            throw CheckFailure.failed("missing helper did not fail")
        } catch SiteAppBundle.Failure.helper { }
        try check(!FileManager.default.fileExists(atPath: badApps.path), "missing helper left filesystem artifacts")

        let badAddressApps = root.appendingPathComponent("invalid-address-target", isDirectory: true)
        do {
            _ = try SiteAppBundle.create(name: "Invalid", url: URL(fileURLWithPath: "/etc/passwd"),
                                         in: badAddressApps, helper: helper, browser: browser, icon: nil)
            throw CheckFailure.failed("invalid URL did not fail creation")
        } catch SiteAppBundle.Failure.address { }
        try check(!FileManager.default.fileExists(atPath: badAddressApps.path),
                  "invalid address left installation artifacts")

        let remaining = try FileManager.default.contentsOfDirectory(atPath: apps.path)
        try check(!remaining.contains(where: { $0.hasPrefix(".search-site-") }),
                  "successful creation left a staging directory behind")

        print("Site app bundle checks passed")
    }
}

enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { if case let .failed(message) = self { return message }; return "failed" }
}
