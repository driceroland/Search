import Foundation

// A site app is made here, on this Mac, from the small WebKit host shipped
// inside Search. No compiler, downloaded code, or copy of Search's profile.
enum SiteAppBundle {
    enum Failure: LocalizedError {
        case address, name, helper, signing

        var errorDescription: String? {
            switch self {
            case .address: return "Choose an http or https page without a username or password in its address."
            case .name: return "Give the app a name containing more than spaces or punctuation."
            case .helper: return "The site app helper is missing. Build or reinstall the complete Search app and try again."
            case .signing: return "macOS could not sign the new app. Nothing was installed."
            }
        }
    }

    static func accepts(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            && !(url.host?.isEmpty ?? true) && url.user == nil && url.password == nil
    }

    /// The title comes from a page. It is a name, never a path or a command.
    static func name(from title: String) throws -> String {
        let forbidden = CharacterSet.controlCharacters.union(.illegalCharacters)
            .union(CharacterSet(charactersIn: "/\\:"))
        var name = String(title.unicodeScalars.map { forbidden.contains($0) ? "-" : String($0) }.joined())
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if name.lowercased().hasSuffix(".app") { name.removeLast(4) }
        // Leave room for a collision suffix, including on filesystems whose
        // limit counts bytes instead of characters.
        while name.utf8.count > 180 { name.removeLast() }
        guard !name.isEmpty, name.contains(where: { $0.isLetter || $0.isNumber }) else { throw Failure.name }
        return name
    }

    static func create(
        name title: String, url: URL, in applications: URL,
        helper: URL, browser: Bundle, icon: Data?
    ) throws -> URL {
        guard accepts(url) else { throw Failure.address }
        let name = try name(from: title)
        let files = FileManager.default
        guard files.isExecutableFile(atPath: helper.path),
              (try? files.attributesOfItem(atPath: helper.path)[.type] as? FileAttributeType) == .typeRegular
        else { throw Failure.helper }
        try files.createDirectory(at: applications, withIntermediateDirectories: true)
        let staging = applications.appendingPathComponent(".search-site-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }

        let app = staging.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let executables = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try files.createDirectory(at: executables, withIntermediateDirectories: true)
        try files.createDirectory(at: resources, withIntermediateDirectories: true)
        let executable = executables.appendingPathComponent("SearchSite")
        try files.copyItem(at: helper, to: executable)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        var plist: [String: Any] = [
            "CFBundleName": name, "CFBundleDisplayName": name,
            "CFBundleExecutable": "SearchSite", "CFBundlePackageType": "APPL",
            "CFBundleIdentifier": "com.officecommun.search.site.\(UUID().uuidString.lowercased())",
            "CFBundleShortVersionString": browser.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
            "CFBundleVersion": browser.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1",
            "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": true,
            "NSAppTransportSecurity": ["NSAllowsArbitraryLoadsInWebContent": true],
            "SearchSiteURL": url.absoluteString,
            "SearchBrowserBundleIdentifier": browser.bundleIdentifier ?? "com.officecommun.search",
            "SearchBrowserPath": browser.bundleURL.path
        ]
        if let icon {
            try icon.write(to: resources.appendingPathComponent("AppIcon.icns"), options: .atomic)
            plist["CFBundleIconFile"] = "AppIcon"
        }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)

        // Changing a bundle's identity needs a fresh signature. This is a
        // local app, not a new Developer ID release; Search's updater must
        // never replace it. Arguments stay data, even for a hostile title.
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", "--", app.path]
        sign.standardOutput = FileHandle.nullDevice
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        guard sign.terminationStatus == 0 else { throw Failure.signing }

        var destination = applications.appendingPathComponent("\(name).app", isDirectory: true)
        var suffix = 2
        while files.fileExists(atPath: destination.path) {
            destination = applications.appendingPathComponent("\(name) \(suffix).app", isDirectory: true)
            suffix += 1
        }
        // moveItem refuses an existing destination, including one created
        // since the check above. An unrelated app is never replaced.
        try files.moveItem(at: app, to: destination)
        return destination
    }
}
