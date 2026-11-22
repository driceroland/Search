import Foundation

/// Safari web extensions that come inside Mac apps (idea 888, #1272). Such an
/// app carries its extension's manifest and scripts unpacked, in
/// `Contents/PlugIns/<X>.appex/Contents/Resources`, beside a native part
/// that only Safari talks to. Settings › Extensions › From Safari apps, off
/// unless you turn it on, lists those found in /Applications and
/// ~/Applications; Add copies that folder in as any unpacked extension
/// (Extensions.installFolder), asking first with what it wants.
///
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

    /// The Safari web extensions inside one app.
    static func extensions(in app: URL) -> [Found] {
        let plugins = app.appendingPathComponent("Contents/PlugIns", isDirectory: true)
        guard let appexes = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        let appName = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        let appReal = Crx.realPath(of: app)
        return appexes.filter { $0.pathExtension == "appex" }.compactMap { appex in
            guard let info = NSDictionary(contentsOf: appex.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
                  (info["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String == point
            else { return nil }
            let resources = appex.appendingPathComponent("Contents/Resources", isDirectory: true)
            // Its manifest, really inside the app: a link out of the bundle
            // would make "from this app" a lie about where the code comes from.
            let real = Crx.realPath(of: resources)
            guard real.hasPrefix(appReal + "/"),
                  let data = try? Data(contentsOf: resources.appendingPathComponent("manifest.json")),
                  data.count < 1 << 20,
                  let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return nil }
            let given = (manifest["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let name = given.isEmpty || given.hasPrefix("__MSG_") ? appName : given
            let folder = URL(fileURLWithPath: real, isDirectory: true)
            return Found(app: appName, appPath: app.path, name: name, folder: folder, id: Crx.unpackedID(for: folder))
        }
    }
}
