import AppKit
import SwiftUI

/// One icon a web app manifest lists, as the page loaded it.
struct DeveloperManifestIcon: Equatable, Identifiable {
    let url: String
    let sizes: String
    let purpose: String
    let type: String
    /// The image's own size, when it loaded.
    let width: Int?
    let height: Int?
    let failed: Bool
    /// A PNG of at most 64 points a side, when the page may read the image's pixels.
    let thumbnail: Data?

    var id: String { url + "\n" + sizes + "\n" + purpose }

    init(url: String, sizes: String = "", purpose: String = "", type: String = "", width: Int? = nil,
         height: Int? = nil, failed: Bool = false, thumbnail: Data? = nil) {
        self.url = url
        self.sizes = sizes
        self.purpose = purpose
        self.type = type
        self.width = width
        self.height = height
        self.failed = failed
        self.thumbnail = thumbnail
    }

    init?(_ raw: [String: Any]) {
        guard let url = raw["src"] as? String else { return nil }
        self.url = url
        sizes = raw["sizes"] as? String ?? ""
        purpose = raw["purpose"] as? String ?? ""
        type = raw["type"] as? String ?? ""
        width = (raw["width"] as? NSNumber).flatMap { $0.intValue > 0 ? $0.intValue : nil }
        height = (raw["height"] as? NSNumber).flatMap { $0.intValue > 0 ? $0.intValue : nil }
        failed = raw["failed"] as? Bool == true
        if let text = raw["thumbnail"] as? String, let comma = text.firstIndex(of: ","), text.hasPrefix("data:image/png;base64") {
            thumbnail = Data(base64Encoded: String(text[text.index(after: comma)...]))
        } else {
            thumbnail = nil
        }
    }

    /// The sizes the manifest declares: pixels across and down, or nil for "any".
    var declared: [(width: Int, height: Int)?] {
        sizes.lowercased().split(whereSeparator: \.isWhitespace).compactMap { token -> (width: Int, height: Int)?? in
            if token == "any" { return .some(nil) }
            let parts = token.split(separator: "x")
            guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else { return nil }
            return .some((width: width, height: height))
        }
    }

    /// PNG, SVG or WebP, from the declared type or else the address's extension.
    var supportedFormat: Bool {
        let type = type.lowercased()
        if !type.isEmpty { return ["image/png", "image/svg+xml", "image/webp"].contains(type) }
        let path = URL(string: url)?.pathExtension.lowercased() ?? ""
        return ["png", "svg", "webp"].contains(path)
    }

    var purposes: [String] { purpose.lowercased().split(whereSeparator: \.isWhitespace).map(String.init) }
}

/// A colour a manifest names, as the page's canvas resolved it.
struct DeveloperManifestColour: Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    /// Reads what a canvas's `fillStyle` gives back: `#rrggbb`, or
    /// `rgba(r, g, b, a)` for a colour that isn't opaque.
    init?(canvas text: String?) {
        guard var text = text?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty else { return nil }
        if text.hasPrefix("#") {
            text.removeFirst()
            if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
            guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
            let hasAlpha = text.count == 8
            let shift: UInt64 = hasAlpha ? 8 : 0
            red = Double((value >> (16 + shift)) & 0xff) / 255
            green = Double((value >> (8 + shift)) & 0xff) / 255
            blue = Double((value >> shift) & 0xff) / 255
            alpha = hasAlpha ? Double(value & 0xff) / 255 : 1
            return
        }
        guard text.hasPrefix("rgb"), text.hasSuffix(")"), let opener = text.firstIndex(of: "(") else { return nil }
        let inside = text[text.index(after: opener)..<text.index(before: text.endIndex)]
        let parts = inside.split(whereSeparator: { $0 == "," || $0 == "/" || $0 == " " }).compactMap { Double($0) }
        guard parts.count == 3 || parts.count == 4 else { return nil }
        red = min(max(parts[0] / 255, 0), 1)
        green = min(max(parts[1] / 255, 0), 1)
        blue = min(max(parts[2] / 255, 0), 1)
        alpha = parts.count == 4 ? min(max(parts[3], 0), 1) : 1
    }
}

/// A protocol a manifest asks to handle, and the page that handles it.
struct DeveloperManifestProtocolHandler: Equatable, Identifiable {
    let protocolName: String
    let url: String

    var id: String { protocolName + "\n" + url }

    /// The address Chrome opens when a link uses this protocol: `%s` in the
    /// handler's URL replaced by the whole link, escaped as
    /// `encodeURIComponent` escapes it. `input` may leave out the scheme.
    func open(_ input: String) -> String {
        var link = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !link.lowercased().hasPrefix(protocolName.lowercased() + ":") { link = protocolName + ":" + link }
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-_.!~*'()")
        let escaped = link.addingPercentEncoding(withAllowedCharacters: allowed) ?? link
        return url.replacingOccurrences(of: "%s", with: escaped)
    }
}

/// One of the app's shortcuts, as its launcher menu would list it.
struct DeveloperManifestShortcut: Equatable, Identifiable {
    let name: String
    let shortName: String
    let description: String
    let url: String
    let icons: [DeveloperManifestIcon]

    var id: String { name + "\n" + url }
}

/// One of the screenshots a manifest offers for its install dialog.
struct DeveloperManifestScreenshot: Equatable, Identifiable {
    let image: DeveloperManifestIcon
    let formFactor: String
    let label: String
    let platform: String

    var id: String { image.id }
}

/// Chrome's Manifest view checks: "Errors and warnings" for what the
/// manifest gets wrong, and "Installability" for what keeps the page from
/// being installed, worded as Chrome words them.
struct DeveloperManifestReport: Equatable {
    var errors: [String] = []
    var installability: [String] = []
    var icons: [DeveloperManifestIcon] = []

    // Identity
    var name: String?
    var shortName: String?
    var description: String?
    /// The App Id the browser keys the installed app by.
    var appID: String?
    /// The `id` Chrome recommends when the manifest leaves it out, or nil
    /// when the manifest sets one.
    var recommendedID: String?

    // Presentation
    var startURL: String?
    var themeColor: String?
    var themeColour: DeveloperManifestColour?
    var backgroundColor: String?
    var backgroundColour: DeveloperManifestColour?
    var orientation: String?
    var display: String?
    var displayOverride: [String] = []
    var scope: String?

    var protocolHandlers: [DeveloperManifestProtocolHandler] = []
    var shortcuts: [DeveloperManifestShortcut] = []
    var screenshots: [DeveloperManifestScreenshot] = []

    /// Whether `display_override` asks for the Window Controls Overlay.
    var windowControlsOverlay: Bool { displayOverride.contains("window-controls-overlay") }

    /// Chrome's smallest installable icon: 144 pixels square.
    static let smallestIcon = 144
    static let installableDisplays: Set<String> = ["standalone", "fullscreen", "minimal-ui", "window-controls-overlay"]
    static let displays: Set<String> = ["fullscreen", "standalone", "minimal-ui", "browser"]

    /// `raw` is what the read script's `manifestReport` returns.
    static func validate(_ raw: [String: Any]) -> DeveloperManifestReport {
        var report = DeveloperManifestReport()
        let types = raw["types"] as? [String: String] ?? [:]
        func string(_ key: String) -> String? {
            (raw[key] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        for key in ["name", "short_name", "start_url", "scope", "display", "id", "theme_color", "background_color",
                    "orientation"] {
            if let type = types[key], type != "missing", type != "string" {
                report.errors.append("Manifest: property '\(key)' ignored, type string expected.")
            }
        }
        for key in ["icons", "display_override"] {
            if let type = types[key], type != "missing", type != "array" {
                report.errors.append("Manifest: property '\(key)' ignored, type array expected.")
            }
        }

        let document = (raw["documentURL"] as? String).flatMap(URL.init(string:))
        let manifestURL = (raw["manifestURL"] as? String).flatMap(URL.init(string:))
        let display = string("display")?.lowercased()
        if let display, !displays.contains(display) {
            report.errors.append("Manifest: unknown 'display' value '\(display)' ignored.")
        }

        // start_url and scope must be on the document's origin, and the
        // start URL inside the scope.
        var start = document
        if let text = raw["start_url"] as? String {
            if let url = URL(string: text), text != "invalid", sameOrigin(url, document) {
                start = url
            } else {
                report.errors.append("Manifest: property 'start_url' ignored, should be same origin as document.")
                report.installability.append("Manifest start URL is not valid")
            }
        }
        var scope = manifestURL?.deletingLastPathComponent()
        if let text = raw["scope"] as? String {
            if let url = URL(string: text), text != "invalid", sameOrigin(url, document) {
                scope = url
            } else {
                report.errors.append("Manifest: property 'scope' ignored, should be same origin as document.")
            }
        }
        if let start, let scope, !within(start, scope: scope) {
            report.errors.append("Manifest: property 'scope' ignored. Start url should be within scope of scope URL.")
        }

        // Identity and Presentation, as the browser resolves them.
        report.name = string("name")
        report.shortName = string("short_name")
        report.description = string("description")
        report.startURL = start?.absoluteString
        report.scope = scope?.absoluteString
        report.display = display
        report.orientation = string("orientation")
        report.themeColor = string("theme_color")
        report.themeColour = DeveloperManifestColour(canvas: raw["theme_colour"] as? String)
        report.backgroundColor = string("background_color")
        report.backgroundColour = DeveloperManifestColour(canvas: raw["background_colour"] as? String)
        report.displayOverride = (raw["display_override"] as? [String] ?? []).map { $0.lowercased() }
        if let start {
            let id = raw["id"] as? String
            report.appID = appID(id: id, start: start)
            if id?.isEmpty != false { report.recommendedID = recommendedID(start) }
        }
        report.protocolHandlers = (raw["protocol_handlers"] as? [[String: Any]] ?? []).compactMap { handler in
            guard let name = handler["protocol"] as? String, let url = handler["url"] as? String else { return nil }
            return DeveloperManifestProtocolHandler(protocolName: name, url: url)
        }
        report.shortcuts = (raw["shortcuts"] as? [[String: Any]] ?? []).compactMap { shortcut in
            guard let url = shortcut["url"] as? String else { return nil }
            return DeveloperManifestShortcut(
                name: shortcut["name"] as? String ?? "", shortName: shortcut["short_name"] as? String ?? "",
                description: shortcut["description"] as? String ?? "", url: url,
                icons: (shortcut["icons"] as? [[String: Any]] ?? []).compactMap(DeveloperManifestIcon.init))
        }
        report.screenshots = (raw["screenshots"] as? [[String: Any]] ?? []).compactMap { shot in
            guard let image = DeveloperManifestIcon(shot) else { return nil }
            return DeveloperManifestScreenshot(image: image, formFactor: shot["form_factor"] as? String ?? "",
                                               label: shot["label"] as? String ?? "",
                                               platform: shot["platform"] as? String ?? "")
        }

        // Icons: each must load, and match the sizes it declares.
        report.icons = (raw["icons"] as? [[String: Any]] ?? []).compactMap(DeveloperManifestIcon.init)
        for icon in report.icons {
            if icon.failed {
                report.errors.append("Error while trying to use the following icon from the Manifest: \(icon.url) "
                                     + "(Download error or resource isn't a valid image)")
            } else if let width = icon.width, let height = icon.height, !icon.declared.isEmpty,
                      !icon.declared.contains(where: { $0 == nil || ($0?.width == width && $0?.height == height) }) {
                let declared = icon.declared.compactMap { $0 }.map { "\($0.width)×\($0.height)" }.joined(separator: ", ")
                report.errors.append("Actual size (\(width)×\(height))px of icon \(icon.url) does not match specified size (\(declared)px)")
            }
        }
        if raw["controlled"] as? Bool != true {
            report.errors.append((raw["workers"] as? Int ?? 0) > 0
                ? "No service worker controls this page yet. Chrome no longer needs one to install the app, but it won't work offline."
                : "No service worker is registered. Chrome no longer needs one to install the app, but it won't work offline.")
        }

        // Installability, as Chrome's InstallableManager reports it.
        if raw["secure"] as? Bool != true {
            report.installability.append("Page is not served from a secure origin")
        }
        if string("name") == nil && string("short_name") == nil {
            report.installability.append("Manifest does not contain a 'name' or 'short_name' field")
        }
        let effective = report.displayOverride.first(where: installableDisplays.contains) ?? display ?? "browser"
        if !installableDisplays.contains(effective) {
            report.installability.append("Manifest 'display' property must be one of 'standalone', 'fullscreen', or 'minimal-ui'")
        }
        if !report.icons.contains(where: suitable) {
            report.installability.append("Manifest does not contain a suitable icon - PNG, SVG or WebP format of at least "
                + "\(smallestIcon)px is required, the sizes attribute must be set, and the purpose attribute, if set, must include \"any\".")
        }
        return report
    }

    /// An icon Chrome would install the app with: a supported format, at
    /// least 144 pixels square or "any" size, and meant for "any" purpose.
    static func suitable(_ icon: DeveloperManifestIcon) -> Bool {
        guard !icon.failed, icon.supportedFormat else { return false }
        let purposes = icon.purposes
        guard purposes.isEmpty || purposes.contains("any") else { return false }
        return icon.declared.contains { size in
            guard let size else { return true }
            return size.width == size.height && size.width >= smallestIcon
        }
    }

    /// The App Id, as the manifest spec computes it: `id` resolved against
    /// the start URL's origin, or the start URL itself when `id` is missing,
    /// empty, unparsable or on another origin; without a fragment either way.
    static func appID(id: String?, start: URL) -> String {
        var result = start
        if let id, !id.isEmpty, let origin = DeveloperApplication.origin(of: start),
           let resolved = URL(string: id, relativeTo: origin)?.absoluteURL,
           DeveloperApplication.origin(of: resolved) == origin {
            result = resolved
        }
        guard var parts = URLComponents(url: result, resolvingAgainstBaseURL: true) else { return result.absoluteString }
        parts.fragment = nil
        return parts.url?.absoluteString ?? result.absoluteString
    }

    /// What Chrome suggests putting in `id` to keep the App Id the start URL
    /// gives today: the start URL's path and query.
    static func recommendedID(_ start: URL) -> String {
        guard let parts = URLComponents(url: start, resolvingAgainstBaseURL: true) else { return "/" }
        var path = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
        if let query = parts.percentEncodedQuery { path += "?" + query }
        return path
    }

    private static func sameOrigin(_ url: URL, _ document: URL?) -> Bool {
        guard let document else { return true }
        return DeveloperApplication.origin(of: url) == DeveloperApplication.origin(of: document)
    }

    /// Whether `url` is inside `scope`: the same origin, and its path starts with the scope's.
    static func within(_ url: URL, scope: URL) -> Bool {
        guard DeveloperApplication.origin(of: url) == DeveloperApplication.origin(of: scope) else { return false }
        let path = url.path.isEmpty ? "/" : url.path
        var prefix = scope.path.isEmpty ? "/" : scope.path
        if scope.absoluteString.hasSuffix("/"), !prefix.hasSuffix("/") { prefix += "/" }
        return path.hasPrefix(prefix) || path + "/" == prefix
    }
}

/// Application › Manifest, as Chrome lays it out: the problems first
/// (Errors and warnings, Installability), then the manifest's members, then
/// its icons at the size the page loaded them.
struct DeveloperManifestView: View {
    let rows: [DeveloperApplicationSnapshot.Row]
    let report: DeveloperManifestReport

    /// "Show only the minimum safe area for maskable icons": maskable icons
    /// drawn inside the circle of 40% radius every platform mask keeps.
    @State private var safeArea = false
    @State private var testedProtocol = ""
    @State private var testInput = ""
    @State private var testedURL: String?

    /// Property rows the Identity, Presentation, Icons, Shortcuts and
    /// Screenshots sections already show.
    static func sectioned(_ label: String) -> Bool {
        let shown: Set<String> = ["Name", "Short name", "Description", "Display", "Orientation", "Theme color",
                                  "Background color", "ID", "Start URL", "Scope", "Display override"]
        return shown.contains(label) || label.hasPrefix("Icon") || label.hasPrefix("Screenshot")
            || label.hasPrefix("Shortcut")
    }

    @ViewBuilder private func field(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label).foregroundStyle(.secondary)
                Text(value).font(DeveloperToolsStyle.code).textSelection(.enabled).lineLimit(3)
            }
        }
    }

    @ViewBuilder private func colour(_ label: String, _ value: String?, _ colour: DeveloperManifestColour?) -> some View {
        if let value {
            GridRow {
                Text(label).foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    if let colour {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(.sRGB, red: colour.red, green: colour.green, blue: colour.blue,
                                        opacity: colour.alpha))
                            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.secondary.opacity(0.5)))
                            .frame(width: 12, height: 12)
                            .accessibilityHidden(true)
                    }
                    Text(value).font(DeveloperToolsStyle.code).textSelection(.enabled)
                }
            }
        }
    }

    /// Protocol handlers, with Chrome's box for trying one: pick the
    /// protocol, type the rest of a link, and see the page it opens.
    private var protocols: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Found valid protocol handler registration in the manifest. With the app installed, test the "
                  + "registered protocols.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                ForEach(report.protocolHandlers) { handler in
                    GridRow {
                        Text(handler.protocolName).font(DeveloperToolsStyle.code)
                        Text(handler.url).font(DeveloperToolsStyle.code).textSelection(.enabled).lineLimit(2)
                    }
                }
            }
            HStack(spacing: 6) {
                Picker("Protocol", selection: $testedProtocol) {
                    ForEach(report.protocolHandlers) { handler in
                        Text(handler.protocolName).tag(handler.protocolName)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 160)
                TextField("Enter URL", text: $testInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .onSubmit(testProtocol)
                Button("Test protocol", action: testProtocol)
            }
            if let testedURL {
                HStack(spacing: 4) {
                    Text("Opens").foregroundStyle(.secondary)
                    Text(testedURL).font(DeveloperToolsStyle.code).textSelection(.enabled).lineLimit(2)
                }
            }
        }
        .onAppear {
            if testedProtocol.isEmpty { testedProtocol = report.protocolHandlers.first?.protocolName ?? "" }
        }
    }

    private func testProtocol() {
        let handler = report.protocolHandlers.first { $0.protocolName == testedProtocol } ?? report.protocolHandlers.first
        testedURL = handler?.open(testInput)
    }

    private func screenshot(_ shot: DeveloperManifestScreenshot, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Screenshot #\(index + 1)").font(.system(size: 11, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                field("Form factor", shot.formFactor)
                field("Label", shot.label)
                field("Platform", shot.platform)
                field("Sizes", shot.image.sizes)
            }
            Group {
                if let data = shot.image.thumbnail, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                        .frame(maxWidth: 240, maxHeight: 240, alignment: .leading)
                } else {
                    Image(systemName: shot.image.failed ? "exclamationmark.triangle" : "photo")
                        .font(.system(size: 20)).foregroundStyle(.secondary)
                        .frame(width: 64, height: 64)
                        .background(DeveloperToolsStyle.raised, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .help(shot.image.url)
            Text(shot.image.url).font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                errorsSection
                installabilitySection
                propertiesSection
                identitySection
                presentationSection
                if !report.protocolHandlers.isEmpty {
                    section("Protocol handlers") { protocols }
                }
                iconsSection
                shortcutsSection
                screenshotsSection
                overlaySection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }

    private var errorsSection: some View {
        section("Errors and warnings") {
            if report.errors.isEmpty {
                Text("No errors or warnings").foregroundStyle(.secondary)
            } else {
                ForEach(Array(report.errors.enumerated()), id: \.offset) { _, error in
                    problem(error, symbol: "exclamationmark.triangle.fill", color: .orange)
                }
            }
        }
    }

    private var installabilitySection: some View {
        section("Installability") {
            if report.installability.isEmpty {
                Label("This page can be installed as an app", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                ForEach(Array(report.installability.enumerated()), id: \.offset) { _, reason in
                    problem(reason, symbol: "xmark.octagon.fill", color: .red)
                }
            }
        }
    }

    @ViewBuilder
    private var propertiesSection: some View {
        let others: [DeveloperApplicationSnapshot.Row] = rows.filter { !Self.sectioned($0.values.first ?? "") }
        if !others.isEmpty {
            section("Properties") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    ForEach(others) { (row: DeveloperApplicationSnapshot.Row) in
                        GridRow {
                            Text(row.values.first ?? "").foregroundStyle(.secondary)
                            Text(row.values.dropFirst().first ?? "")
                                .font(DeveloperToolsStyle.code)
                                .textSelection(.enabled)
                                .lineLimit(3)
                        }
                    }
                }
            }
        }
    }

    private var identitySection: some View {
        section("Identity") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                field("Name", report.name)
                field("Short name", report.shortName)
                field("Description", report.description)
                field("Computed App Id", report.appID)
            }
            if let recommended = report.recommendedID { recommendedNote(recommended) }
        }
    }

    private func recommendedNote(_ recommended: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "info.circle").foregroundStyle(.secondary).accessibilityHidden(true)
            Text("Note: id is not specified in the manifest, start_url is used instead. To specify an App Id "
                 + "that matches the current identity, set the id field to \(recommended).")
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Button("Copy") { DeveloperToolsSession.copyToPasteboard(recommended) }
            .controlSize(.small)
            .help("Copy suggested ID to clipboard")
        }
    }

    private var presentationSection: some View {
        let displayOverride: String? = report.displayOverride.isEmpty ? nil
            : report.displayOverride.joined(separator: ", ")
        return section("Presentation") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                field("Start URL", report.startURL)
                colour("Theme color", report.themeColor, report.themeColour)
                colour("Background color", report.backgroundColor, report.backgroundColour)
                field("Orientation", report.orientation)
                field("Display", report.display)
                field("Display override", displayOverride)
                field("Scope", report.scope)
            }
        }
    }

    @ViewBuilder
    private var iconsSection: some View {
        if !report.icons.isEmpty {
            section("Icons") {
                Toggle("Show only the minimum safe area for maskable icons", isOn: $safeArea)
                    .toggleStyle(.developerCheckbox)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .top)], alignment: .leading,
                          spacing: 12) {
                    ForEach(report.icons) { icon($0) }
                }
            }
        }
    }

    @ViewBuilder
    private var shortcutsSection: some View {
        if !report.shortcuts.isEmpty {
            section("Shortcuts") {
                ForEach(Array(report.shortcuts.enumerated()), id: \.offset) { index, shortcut in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Shortcut #\(index + 1)").font(.system(size: 11, weight: .semibold))
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                            field("Name", shortcut.name)
                            field("Short name", shortcut.shortName)
                            field("Description", shortcut.description)
                            field("URL", shortcut.url)
                        }
                        if !shortcut.icons.isEmpty {
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(shortcut.icons) { icon($0) }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var screenshotsSection: some View {
        if !report.screenshots.isEmpty {
            section("Screenshots") {
                ForEach(Array(report.screenshots.enumerated()), id: \.offset) { index, shot in
                    screenshot(shot, index: index)
                }
            }
        }
    }

    private var overlaySection: some View {
        section("Window Controls Overlay") {
            if report.windowControlsOverlay {
                Label("Chrome has successfully found the window-controls-overlay value for the display_override field.",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text("Define window-controls-overlay in the display_override field of the manifest to use the "
                     + "Window Controls Overlay API and customize your app's title bar.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func problem(_ text: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
            Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func icon(_ icon: DeveloperManifestIcon) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Group {
                if let data = icon.thumbnail, let image = NSImage(data: data) {
                    if safeArea && icon.purposes.contains("maskable") {
                        // The safe zone: a centred circle whose radius is 40% of the icon's side.
                        Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                            .clipShape(Circle().scale(0.8))
                    } else {
                        Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    }
                } else {
                    Image(systemName: icon.failed ? "exclamationmark.triangle" : "photo")
                        .font(.system(size: 20)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 64)
            .background(DeveloperToolsStyle.raised, in: RoundedRectangle(cornerRadius: 4))
            .help(icon.url)
            Text(icon.sizes.isEmpty ? "No sizes" : icon.sizes).font(DeveloperToolsStyle.code)
            if let width = icon.width, let height = icon.height {
                Text("Actual \(width)×\(height)").foregroundStyle(.secondary)
            } else if icon.failed {
                Text("Didn’t load").foregroundStyle(.secondary)
            }
            if !icon.purpose.isEmpty { Text(icon.purpose).foregroundStyle(.secondary) }
            Text(URL(string: icon.url)?.lastPathComponent ?? icon.url)
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }
}
