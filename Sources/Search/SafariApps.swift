import Foundation
import Security

/// Safari web extensions that come inside Mac apps (idea 888, #1272). Such an
/// app carries its extension's manifest and scripts unpacked, in
/// `Contents/PlugIns/<X>.appex/Contents/Resources`, beside a native part
/// that only Safari talks to. Settings › Extensions › From Safari apps, off
/// unless you turn it on, lists those found in /Applications and
/// ~/Applications; Add copies that folder in as any unpacked extension
/// (Extensions.installFolder), asking first with what it wants.
///
/// Only an extension whose .appex carries a signature that holds (Apple,
/// Mac App Store or Developer ID) is listed, checked again on Add and Reload.
/// Read only: nothing in another app's bundle is ever written, and nothing in
/// it runs but the extension's own JavaScript, in Search's extension
/// sandbox. The app's native code (the .appex's executable, the app itself)
/// is never loaded or launched, so `sendNativeMessage` to it finds nobody,
/// and a Safari content blocker (a different kind of .appex, a JSON rule list
/// with no manifest.json) isn't listed at all.
enum SafariApps {
    /// The key Settings › Extensions › From Safari apps keeps its switch under.
    static let key = "extensions.safariApps"

    /// What `com.apple.Safari.web-extension` names in an .appex's Info.plist.
    static let point = "com.apple.Safari.web-extension"

    struct Found: Equatable {
        /// The app the extension came in, as Finder names it.
        let app: String
        /// The app's own bundle, for its icon.
        let appPath: String
        /// The extension's name from its manifest, or the app's when the
        /// manifest only points at a translation (__MSG_…__).
        let name: String
        /// The folder with manifest.json: what Add copies in.
        let folder: URL
        /// The id Search gives it once added (Crx.unpackedID of `folder`).
        let id: String
    }

    static var on: Bool { Store.settings.bool(forKey: key) }

    /// Where apps are looked for: the two Applications folders, and one
    /// level of folders inside them (Utilities, a vendor's own folder).
    static var places: [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
    }

    /// Every Safari web extension found in apps under `places`, by app name.
    /// Only reads directories and plists; nothing is opened for writing.
    static func scan(in places: [URL] = places) -> [Found] {
        let files = FileManager.default
        var apps: [URL] = []
        for place in places {
            guard let items = try? files.contentsOfDirectory(at: place, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for item in items {
                if item.pathExtension == "app" {
                    apps.append(item)
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                          let inner = try? files.contentsOfDirectory(at: item, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    apps += inner.filter { $0.pathExtension == "app" }
                }
            }
        }
        var found: [Found] = []
        var seen: Set<String> = []
        for app in apps {
            for item in extensions(in: app) where seen.insert(item.id).inserted { found.append(item) }
        }
        return found.sorted { "\($0.app) \($0.name)".localizedStandardCompare("\($1.app) \($1.name)") == .orderedAscending }
    }

    /// The Safari web extensions inside one app. Each must be sealed by a
    /// signature that holds (`vouched`), its Resources a real folder of the
    /// .appex itself (no link anywhere on the way), its Info.plist and
    /// manifest.json plain files of a sane size.
    static func extensions(in app: URL) -> [Found] {
        let plugins = app.appendingPathComponent("Contents/PlugIns", isDirectory: true)
        guard let appexes = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        let appName = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        let appReal = Crx.realPath(of: app)
        return appexes.filter { $0.pathExtension == "appex" }.compactMap { appex in
            let appexReal = Crx.realPath(of: appex)
            guard appexReal.hasPrefix(appReal + "/"),
                  let plist = small(appex.appendingPathComponent("Contents/Info.plist"), limit: 256 << 10),
                  let info = (try? PropertyListSerialization.propertyList(from: plist, format: nil)) as? [String: Any],
                  (info["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String == point
            else { return nil }
            let resources = appex.appendingPathComponent("Contents/Resources", isDirectory: true)
            // Its manifest, really inside the extension: a link out of it
            // would make "from this app" a lie about where the code comes
            // from, and put files the signature doesn't seal in its place.
            let real = Crx.realPath(of: resources)
            guard real == appexReal + "/Contents/Resources",
                  let data = small(resources.appendingPathComponent("manifest.json"), limit: 1 << 20),
                  let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  vouched(URL(fileURLWithPath: appexReal, isDirectory: true))
            else { return nil }
            let given = (manifest["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let name = given.isEmpty || given.hasPrefix("__MSG_") ? appName : String(given.prefix(80))
            let folder = URL(fileURLWithPath: real, isDirectory: true)
            return Found(app: appName, appPath: app.path, name: name, folder: folder, id: Crx.unpackedID(for: folder))
        }
    }

    /// Whether `folder` (a Found's) is still a Safari web extension that
    /// `extensions(in:)` would list, signature and all: checked again on Add
    /// and on Reload, as the app may have changed since it was listed.
    static func still(_ folder: URL) -> Bool {
        let real = URL(fileURLWithPath: Crx.realPath(of: folder), isDirectory: true)
        guard real.path == folder.path, real.lastPathComponent == "Resources" else { return false }
        // Resources → Contents → X.appex → PlugIns → Contents → X.app
        let appex = real.deletingLastPathComponent().deletingLastPathComponent()
        let app = appex.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard appex.pathExtension == "appex", app.pathExtension == "app" else { return false }
        return extensions(in: app).contains { $0.folder.path == real.path }
    }

    /// The extension `name` already added some other way: the same one from
    /// the Chrome Web Store (Grammarly, 1Password, Dark Reader…), or from
    /// another app. Added again, it ran twice, every page done over by both.
    /// Told by the name it goes by, the part before a colon or a dash, with
    /// "for Safari" and the like left off: the stores' own names for one
    /// extension differ past that ("Grammarly for Safari", "Grammarly: AI
    /// Writing Assistant and Grammar Checker App").
    static func twin(of name: String, id: String? = nil, among installed: [Installed]) -> Installed? {
        installed.first { $0.id != id && same($0.name, name) }
    }

    /// The same extension added already another way, said before adding it
    /// again: both would run on every page (twin).
    static func twinLine(_ twin: Installed) -> String {
        let how = twin.fromApp.map { "from the Safari extension in “\($0)”" }
            ?? (twin.fromStore ? "from the Chrome Web Store" : "already")
        return "“\(twin.name)” is added \(how): with this one too, both would run."
    }

    /// Whether two extensions' names are one extension's: one's words the
    /// start of the other's, after `brand`, and not a short common word.
    static func same(_ a: String, _ b: String) -> Bool {
        let x = brand(a), y = brand(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        let (short, long) = x.count <= y.count ? (x, y) : (y, x)
        guard Array(long.prefix(short.count)) == short else { return false }
        return short == long || short.joined().count >= 4
    }

    /// The words of the name an extension goes by, folded: up to its first
    /// colon, dash, bar or bracket, without a trailing "for Safari",
    /// "extension" or the like.
    static func brand(_ name: String) -> [String] {
        var text = name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        for cut in [":", " - ", " – ", " — ", "|", "(", "®", "™"] {
            if let at = text.range(of: cut) { text = String(text[..<at.lowerBound]) }
        }
        var words = text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let filler: Set<String> = ["for", "safari", "chrome", "extension", "web", "browser", "app", "on"]
        while words.count > 1, let last = words.last, filler.contains(last) { words.removeLast() }
        return words
    }

    /// Adds `item` through the unpacked-extension path, once `still` says it
    /// is what was listed.
    @available(macOS 15.4, *)
    @MainActor static func add(_ item: Found, to extensions: Extensions, confirm: Bool = true) {
        Task {
            let holds = await Task.detached(priority: .userInitiated) { still(item.folder) }.value
            guard holds else {
                extensions.browser?.announce("\(item.name) wasn't added — \(item.app) has changed or isn't signed")
                return
            }
            extensions.installFolder(at: item.folder, confirm: confirm, fromApp: item.app)
        }
    }

    /// What Safari itself would take: a signature that holds over the
    /// .appex and every file it seals, from Apple, the Mac App Store or a
    /// Developer ID. A test run takes any signature that holds (its made-up
    /// apps are signed ad hoc), never none.
    static func vouched(_ appex: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appex as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        if !Store.testing {
            let text = "anchor apple or (anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists)"
                + " or (anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists)"
            guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return false }
        }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    /// A plain file's bytes, if it is one (not a link, a pipe or a device)
    /// and no bigger than `limit`; read without following links or waiting.
    static func small(_ file: URL, limit: Int) -> Data? {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= limit,
              let data = try? handle.read(upToCount: limit + 1), data.count <= limit
        else { return nil }
        return data
    }
}
