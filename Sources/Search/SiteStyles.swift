import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// One look for a site: its color, type, and any CSS or JavaScript you add.
//
// Off until you turn it on in Settings › Browsing › Pages. Then View ›
// Customize Site…, or the same item in a tab's menu, edits the site you're on. The color and type go in before the page
// draws, the way something you've hidden does (see Curtain), and the
// JavaScript runs once the page has loaded, in the page's own world, so it
// can change that page. Both are kept on this Mac in styles.json. Closing
// the panel keeps them. A private tab is left as the site sent it: the
// panel stays closed, and a look is neither written nor applied there.
//
// The first version of the file stored a site's CSS as a string. That still
// reads, as a look with only that CSS.
//
// CSS is put in as text, so it can't close the style element and run as
// script. An imported sheet, or a web address written plainly in url(), is
// left out. That is not everything a page can ask for: a script you save
// runs in the page. JavaScript is stored as you typed it. Laying the CSS
// out only adds whitespace, and only after `clean`.

@MainActor
final class SiteStyles: ObservableObject {
    static let shared = SiteStyles()
    /// The element the sheet lives in, apart from the one that hides things.
    static let element = "office-style"
    /// Off until Settings says so. Read where a page is armed, which has no
    /// preferences of its own to ask.
    static var on = false
    /// Long enough for a site, short of a library pasted in by mistake.
    static let limit = 32_000
    /// Faces a site may be set in. Anything else would be a name we can't
    /// trust inside a stylesheet. Only the ones this Mac actually has.
    static let faces: [String] = {
        let have = Set(NSFontManager.shared.availableFontFamilies)
        return ["New York", "Georgia", "Palatino", "Avenir Next", "Helvetica Neue",
                "Gill Sans", "Futura", "Didot", "American Typewriter", "Menlo"]
            .filter { have.contains($0) }
    }()

    @Published private(set) var byHost: [String: SiteLook] = [:]
    /// One write at a time. A second change while a write is out does not
    /// start another until that one has landed, so an older file cannot
    /// arrive after a newer one.
    private var writing = false
    private var pending = false

    private init() { load() }

    func look(on host: String?) -> SiteLook {
        guard let host else { return SiteLook() }
        return byHost[host] ?? SiteLook()
    }

    var hosts: [String] { Array(byHost.keys) }

    /// The sheet for a site, when its look is on. Empty when it is paused,
    /// so the page goes back to itself without the look being forgotten.
    func css(on host: String?) -> String? {
        guard let host, let look = byHost[host], look.on else { return nil }
        let sheet = Self.composed(look)
        return sheet.isEmpty ? nil : sheet
    }

    /// JavaScript for a site, when its look is on. Run once, as the page
    /// loads: running it again when a color changes would repeat whatever it
    /// does.
    func script(on host: String?) -> String? {
        guard let host, let look = byHost[host], look.on else { return nil }
        let source = look.script.trimmingCharacters(in: .whitespacesAndNewlines)
        return source.isEmpty ? nil : source
    }

    /// A change to the color or the type. The CSS and JavaScript are kept
    /// as they were; those wait for Save.
    func revise(on host: String, _ edit: (inout SiteLook) -> Void) {
        var look = byHost[host] ?? SiteLook()
        edit(&look)
        look.text = Self.hex(look.text)
        look.background = Self.hex(look.background)
        look.font = Self.safeFont(look.font)
        if !(80...200).contains(look.size) { look.size = 100 }
        look.name = String(look.name.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        store(look, on: host)
        applyOpen()
    }

    /// Nothing to turn off until the site has a look.
    func setOn(_ on: Bool, host: String) {
        guard byHost[host] != nil else { return }
        revise(on: host) { $0.on = on }
    }

    /// The CSS and JavaScript. A web address written plainly in the CSS is
    /// left out. The JavaScript is kept as typed. A look with nothing left
    /// is forgotten.
    @discardableResult
    func keepCode(css raw: String, script rawScript: String, on host: String) -> Cleaned {
        var look = byHost[host] ?? SiteLook()
        let cleaned = Self.clean(raw)
        look.css = cleaned.css.isEmpty ? "" : Self.arranged(cleaned.css)
        look.script = Self.keptScript(rawScript)
        store(look, on: host)
        applyOpen()
        return cleaned
    }

    /// A look read from a file you picked. Its CSS goes through the same
    /// gate as CSS you typed. Its JavaScript is not stored: the panel holds
    /// that until you save it, so an imported script is read before it runs.
    func replace(_ raw: SiteLook, on host: String) {
        var look = raw
        look.text = Self.hex(look.text)
        look.background = Self.hex(look.background)
        look.font = Self.safeFont(look.font)
        if !(80...200).contains(look.size) { look.size = 100 }
        look.name = String(look.name.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = Self.clean(look.css)
        look.css = cleaned.css.isEmpty ? "" : Self.arranged(cleaned.css)
        look.script = byHost[host]?.script ?? ""
        store(look, on: host)
        applyOpen()
    }

    /// Clears the look and keeps the name, so a site you've named can start
    /// again without losing the name.
    func reset(on host: String) {
        var look = SiteLook()
        look.name = byHost[host]?.name ?? ""
        store(look, on: host)
        applyOpen()
    }

    func remove(on host: String) {
        guard byHost[host] != nil else { return }
        byHost[host] = nil
        save()
        applyOpen()
    }

    /// The pages open now, so a change of color or type shows without a
    /// reload. JavaScript is left as it was: this runs for a color too, and
    /// running the script again would repeat it. Asleep pages are left
    /// alone: waking one would load it, and the next load arms it. A private
    /// tab is left alone too: nothing there is written down, and the page
    /// stays as the site sent it.
    func applyOpen() {
        for tab in openTabs {
            guard let web = tab.built, !tab.shy, let host = Dusk.host(of: tab.address) else { continue }
            let sheet = Self.on ? (css(on: host) ?? "") : ""
            web.evaluateJavaScript(Veiling.style(sheet, id: Self.element), in: nil, in: Web.world) { _ in }
        }
    }

    /// Runs a site's JavaScript once, on the pages of that site open now.
    /// `watched` is the page whose error, if it has one, is reported. A
    /// private tab is skipped, the same way the sheet is. The words are a
    /// line to show, when WebKit has one, so the caret can go there.
    func run(_ source: String, on host: String, watched: Tab?, then: @escaping ((words: String, line: Int)?) -> Void) {
        var watchedRan = false
        for tab in openTabs where !tab.shy && Dusk.host(of: tab.address) == host {
            guard let web = tab.built else { continue }
            let watch = tab === watched
            if watch { watchedRan = true }
            web.evaluateJavaScript(source, in: nil, in: .page) { result in
                guard watch else { return }
                let trouble: (words: String, line: Int)?
                if case .failure(let error) = result { trouble = Self.scriptTrouble(error) }
                else { trouble = nil }
                Task { @MainActor in then(trouble) }
            }
        }
        if !watchedRan { then(nil) }
    }

    /// What WebKit said, short enough for the line under the window. The
    /// line number is the script's own, because the script is injected as
    /// itself and not wrapped.
    private static func scriptTrouble(_ error: Error) -> (words: String, line: Int)? {
        let info = (error as NSError).userInfo
        let said = (info["WKJavaScriptExceptionMessage"] as? String)?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let line = (info["WKJavaScriptExceptionLineNumber"] as? Int)
            ?? (info["WKJavaScriptExceptionLineNumber"] as? NSNumber)?.intValue
            ?? 0
        let words: String
        if let said, !said.isEmpty {
            words = said.count > 60 ? String(said.prefix(60)) + "…" : said
        } else {
            words = "The JavaScript has an error."
        }
        let numbered = line > 0 ? "Saved. Line \(line): \(words)" : "Saved. \(words)"
        return (numbered, line)
    }

    struct Cleaned: Equatable {
        var css: String
        /// Cut down to `limit`.
        var shortened = false
        /// An imported sheet or a web address in url() was left out.
        var fetched = false
    }

    /// What is safe to keep. Relative urls stay: they are the site's own.
    /// Whitespace is left as it was — laying it out is `arranged`'s work.
    static func clean(_ raw: String) -> Cleaned {
        var shortened = false
        var css = raw
        if css.count > limit {
            css = String(css.prefix(limit))
            shortened = true
        }
        let imported = withoutImports(css)
        let fetched = imported != css
        css = imported
        let local = withoutRemoteURLs(css)
        css = local.css
        return Cleaned(
            css: css.trimmingCharacters(in: .whitespacesAndNewlines),
            shortened: shortened,
            fetched: fetched || local.removed
        )
    }

    /// The same CSS, one declaration to a line, so a long line doesn't break
    /// in the middle of a word. A string and a comment are left as they are,
    /// and doing it twice changes nothing.
    static func arranged(_ css: String) -> String {
        var out = ""
        var depth = 0
        var quote: Character?
        var comment = false
        let chars = Array(css)
        var index = 0
        func indent() -> String { String(repeating: "  ", count: max(depth, 0)) }
        func trimTail() {
            while let last = out.last, last == " " || last == "\t" { out.removeLast() }
        }
        func slashed(_ chars: [Character], before index: Int) -> Bool {
            var count = 0
            var cursor = index
            while cursor > 0, chars[cursor - 1] == "\\" {
                count += 1
                cursor -= 1
            }
            return count % 2 == 1
        }
        while index < chars.count {
            let character = chars[index]
            if comment {
                out.append(character)
                if character == "/", index > 0, chars[index - 1] == "*" { comment = false }
                index += 1
                continue
            }
            if let open = quote {
                out.append(character)
                // A backslash keeps the quote, and a backslash before that
                // backslash doesn't. Otherwise "a\"b" would end at the second
                // quote and the rest would be laid out as CSS.
                if character == open, !slashed(chars, before: index) { quote = nil }
                index += 1
                continue
            }
            if character == "/", index + 1 < chars.count, chars[index + 1] == "*" {
                comment = true
                out.append(character)
                index += 1
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                out.append(character)
                index += 1
                continue
            }
            switch character {
            case "{":
                trimTail()
                out += " {\n"
                depth += 1
                out += indent()
            case "}":
                trimTail()
                while out.last == "\n" || out.last == " " { out.removeLast() }
                depth = max(depth - 1, 0)
                out += "\n" + indent() + "}\n" + indent()
            case ";":
                trimTail()
                out += ";\n" + indent()
            case "\n", "\r", "\t":
                if let last = out.last, last != " ", last != "\n" { out.append(" ") }
            case " ":
                if let last = out.last, last != " ", last != "\n" { out.append(" ") }
            default:
                out.append(character)
            }
            index += 1
        }
        trimTail()
        while out.hasSuffix("\n") { out.removeLast() }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// As typed, cut to `limit` if a pasted library ran past it. Not laid
    /// out: turning a line break into a space is a different program.
    static func keptScript(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        return String(text.prefix(limit))
    }


    /// The sheet the page gets: the color and type first, then the CSS you
    /// wrote. The color and type are marked important so a site's own rules
    /// don't hide them; your CSS comes after, so it can say otherwise.
    static func composed(_ look: SiteLook) -> String {
        guard look.on else { return "" }
        var rules: [String] = []
        if look.size != 100, (80...200).contains(look.size) {
            rules.append("html { font-size: \(look.size)% !important; }")
        }
        var page: [String] = []
        var writing: [String] = []
        if let background = hex(look.background) {
            page.append("background-color: \(background) !important")
        }
        if let text = hex(look.text) {
            writing.append("color: \(text) !important")
        }
        if let font = safeFont(look.font) {
            writing.append("font-family: \"\(font)\", sans-serif !important")
        }
        switch look.letters {
        case .same: break
        case .upper: writing.append("text-transform: uppercase !important")
        case .lower: writing.append("text-transform: lowercase !important")
        case .smallCaps: writing.append("font-variant: small-caps !important")
        }
        if !page.isEmpty {
            rules.append("html, body { \(page.joined(separator: "; ")); }")
        }
        if !writing.isEmpty {
            rules.append("body, p, li, a, span, h1, h2, h3, h4, h5, h6, label, button, input, textarea { \(writing.joined(separator: "; ")); }")
        }
        let yours = clean(look.css).css
        if !yours.isEmpty { rules.append(yours) }
        return rules.joined(separator: "\n")
    }

    /// `#rrggbb`, or nothing. Anything else is left out of the sheet.
    static func hex(_ raw: String?) -> String? {
        guard var raw else { return nil }
        raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("#") { raw.removeFirst() }
        guard raw.count == 6, raw.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + raw.lowercased()
    }

    static func color(_ hex: String?) -> NSColor? {
        guard let hex = self.hex(hex) else { return nil }
        var number: UInt64 = 0
        Scanner(string: String(hex.dropFirst())).scanHexInt64(&number)
        return NSColor(
            srgbRed: CGFloat((number >> 16) & 0xff) / 255,
            green: CGFloat((number >> 8) & 0xff) / 255,
            blue: CGFloat(number & 0xff) / 255,
            alpha: 1
        )
    }

    static func hex(of color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        let red = Int((rgb.redComponent * 255).rounded())
        let green = Int((rgb.greenComponent * 255).rounded())
        let blue = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", red, green, blue)
    }

    /// A family name, and nothing a stylesheet could read as syntax.
    static func safeFont(_ name: String?) -> String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80,
              trimmed.allSatisfy({ $0.isLetter || $0 == " " || $0 == "-" }) else { return nil }
        return trimmed
    }

    // MARK: - the file

    private static var file: URL { Store.file("styles.json") }

    private var openTabs: [Tab] {
        Browsers.all.flatMap { $0.tabs + [$0.peekTab].compactMap { $0 } } + LittleWindow.all.map(\.tab)
    }

    private func store(_ look: SiteLook, on host: String) {
        if look.isBlank { byHost[host] = nil } else { byHost[host] = look }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.file) else { return }
        if let looks = try? JSONDecoder().decode([String: SiteLook].self, from: data) {
            byHost = looks
            return
        }
        // The first version stored the CSS alone.
        if let sheets = try? JSONDecoder().decode([String: String].self, from: data) {
            byHost = sheets.mapValues { SiteLook(css: $0) }
        }
    }

    private func save() {
        pending = true
        guard !writing else { return }
        writing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.write()
        }
    }

    private func write() {
        guard pending else {
            writing = false
            return
        }
        pending = false
        let snapshot = byHost
        let file = Self.file
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try? data.write(to: file, options: .atomic)
            }
            DispatchQueue.main.async { [weak self] in self?.finishWrite() }
        }
    }

    private func finishWrite() {
        guard pending else {
            writing = false
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.write()
        }
    }

    /// `@import`, to the semicolon or the end. A sheet it names is another
    /// file, and that file can be on another machine.
    private static func withoutImports(_ css: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "@import\\b[^;]*;?",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return css }
        return regex.stringByReplacingMatches(in: css, range: NSRange(css.startIndex..., in: css), withTemplate: "")
    }

    /// `url(https://…)`, `url(//…)`, `url(javascript:…)`. A relative url, a
    /// fragment and a data url stay.
    private static func withoutRemoteURLs(_ css: String) -> (css: String, removed: Bool) {
        var out = ""
        var removed = false
        var index = css.startIndex
        let lower = css.lowercased()
        while let start = lower.range(of: "url(", range: index..<lower.endIndex) {
            out += css[index..<start.lowerBound]
            guard let end = closeParen(in: css, from: start.upperBound) else {
                out += css[start.lowerBound...]
                return (out, removed)
            }
            let inner = css[start.upperBound..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            let bare = inner.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).lowercased()
            if bare.hasPrefix("http:") || bare.hasPrefix("https:") || bare.hasPrefix("//") || bare.hasPrefix("javascript:") {
                out += "none"
                removed = true
            } else {
                out += css[start.lowerBound...end]
            }
            index = css.index(after: end)
        }
        out += css[index...]
        return (out, removed)
    }

    /// The `)` that closes a `url(`, respecting quotes so a quote can hold one.
    private static func closeParen(in css: String, from start: String.Index) -> String.Index? {
        var quote: Character?
        var index = start
        while index < css.endIndex {
            let character = css[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ")" {
                return index
            }
            index = css.index(after: index)
        }
        return nil
    }
}

/// What one site has been set to. `on` pauses it without forgetting it.
struct SiteLook: Codable, Equatable {
    var name: String = ""
    var on: Bool = true
    var text: String?
    var background: String?
    var font: String?
    var size: Int = 100
    var letters: Letters = .same
    var css: String = ""
    var script: String = ""

    enum Letters: String, Codable, Hashable {
        case same, upper, lower, smallCaps
    }

    init() {}
    init(css: String) { self.css = css }

    var isBlank: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text == nil && background == nil && font == nil
            && size == 100 && letters == .same
            && css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private enum Key: String, CodingKey {
        case name, on, text, background, font, size, letters, css, script
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: Key.self)
        name = try box.decodeIfPresent(String.self, forKey: .name) ?? ""
        on = try box.decodeIfPresent(Bool.self, forKey: .on) ?? true
        text = try box.decodeIfPresent(String.self, forKey: .text)
        background = try box.decodeIfPresent(String.self, forKey: .background)
        font = try box.decodeIfPresent(String.self, forKey: .font)
        size = try box.decodeIfPresent(Int.self, forKey: .size) ?? 100
        letters = try box.decodeIfPresent(Letters.self, forKey: .letters) ?? .same
        css = try box.decodeIfPresent(String.self, forKey: .css) ?? ""
        script = try box.decodeIfPresent(String.self, forKey: .script) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: Key.self)
        try box.encode(name, forKey: .name)
        try box.encode(on, forKey: .on)
        try box.encodeIfPresent(text, forKey: .text)
        try box.encodeIfPresent(background, forKey: .background)
        try box.encodeIfPresent(font, forKey: .font)
        try box.encode(size, forKey: .size)
        try box.encode(letters, forKey: .letters)
        try box.encode(css, forKey: .css)
        try box.encode(script, forKey: .script)
    }
}

// MARK: - the panel

/// The look of the site on screen. A reload leaves it open, words and all.
/// Another website shows that site. A moment with no address is still this site.
struct StylePanel: View {
    @ObservedObject var browser: Browser

    var body: some View {
        Group {
            if let tab = browser.active, !tab.shy {
                StyleEditor(browser: browser, tab: tab)
                    .id(tab.id)
            }
        }
        .onChange(of: browser.activeID) { _, _ in
            if browser.active?.shy == true { browser.styling = false }
        }
    }
}

/// Where the panel is. The code stays where you left it when the page reloads.
private enum StylePane { case look, code, sites }

private enum CodeKind: String, Hashable { case css, javaScript }

/// One site's look. It watches that tab, so a new address on it is seen
/// even when the window itself has nothing new to say.
private struct StyleEditor: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject private var styles = SiteStyles.shared
    /// Hidden things, so the list updates as you take one off the page.
    @ObservedObject private var curtain = Shared.curtain

    @State private var pane: StylePane = .look
    @State private var language: CodeKind = .css
    @State private var cssDraft = ""
    @State private var scriptDraft = ""
    /// The site the words on screen belong to.
    @State private var shown: String?
    @State private var renaming = false
    @State private var nameDraft = ""
    /// Why the CSS just changed under you, until you edit it again.
    @State private var note: String?
    /// The line WebKit named, until the words change.
    @State private var fault: Int?
    /// Closing says this once. The panel can leave by more than one path.
    @State private var mentioned = false

    private var site: String? { Dusk.host(of: tab.address) }
    /// A reload has no address for a moment. The look stays the one you had.
    private var place: String? { site ?? shown }

    private var look: SiteLook { styles.look(on: place) }

    private var title: String {
        if pane == .sites { return "Other Sites" }
        if !look.name.isEmpty { return look.name }
        return place ?? "This page"
    }

    private var codeDirty: Bool {
        let cssSame = SiteStyles.arranged(cssDraft) == SiteStyles.arranged(look.css)
        let scriptSame = scriptDraft.trimmingCharacters(in: .whitespacesAndNewlines) == look.script
        return !cssSame || !scriptSame
    }

    var body: some View {
        Group {
            switch pane {
            case .look: lookPlate
            case .code: codePlate
            case .sites: sitesPlate
            }
        }
        .onAppear { show(site) }
        .onDisappear {
            // The tab in front may already be the next one, and peeking
            // follows that. This is the page the outline was drawn on.
            keepName()
            if let host = browser.curtain.host(of: tab.address) {
                tab.unpeek(browser.curtain.css(on: host))
            }
            warnIfUnsaved()
        }
        .onChange(of: site) { _, next in show(next) }
        .onChange(of: tab.address) { _, next in
            // A reload has no address for a moment, and a navigation can pass
            // through about:blank. A page that isn't a website is a real
            // departure: the panel was still editing the site you left.
            guard let next, next.scheme?.lowercased() != "about", Dusk.host(of: next) == nil else { return }
            warnIfUnsaved()
            close()
        }
        .onChange(of: pane) { _, next in
            if next != .look { stopHiding() }
        }
        .onChange(of: language) { _, _ in fault = nil }
    }

    private var lookPlate: some View {
        Plate(title, width: 440, close: close) {
            VStack(alignment: .leading, spacing: 16) {
                if renaming { renameField }
                if !look.isBlank { useRow }
                VStack(alignment: .leading, spacing: 16) {
                    colors
                    faces
                    typeCard
                    Card {
                        Go("curlybraces", "CSS & JavaScript") { pane = .code }
                    }
                }
                .opacity(!look.isBlank && !look.on ? 0.45 : 1)
                .animation(Motion.quick, value: look.on)
                Card {
                    Go("bolt.slash", browser.veiling ? "Done" : "Hide Elements", on: browser.veiling) {
                        browser.toggleHiding()
                    }
                    .disabled(!(browser.active?.isWeb ?? false))
                }
                if browser.veiling {
                    Caption("Click anything on the page.")
                }
                hidden
            }
        } foot: {
            HStack(spacing: 2) {
                Mark("square.and.arrow.up", "Export", enabled: !look.isBlank) { export() }
                Mark("square.and.arrow.down", "Import", enabled: place != nil) { importFile() }
                Mark("list.bullet", "Other Sites") { pane = .sites }
                Spacer()
                Mark("arrow.counterclockwise", "Reset", enabled: !look.isBlank) { reset() }
                Mark("trash", "Delete", enabled: !look.isBlank) { remove() }
                moreMenu
            }
        }
    }

    private var codePlate: some View {
        Plate(title, width: 440, close: close) {
            VStack(alignment: .leading, spacing: 8) {
                Back { pane = .look }
                Segmented(
                    options: [(.css, "CSS"), (.javaScript, "JavaScript")],
                    selection: $language,
                    wide: true
                )
                Caption(language == .css
                        ? "Applied before the page loads."
                        : "Runs when the page loads.")
                CodeView(text: language == .css ? $cssDraft : $scriptDraft, kind: language, fault: $fault)
                    .id("\(place ?? "")-\(language.rawValue)")
                    .frame(height: 220)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                if language == .css, let note, !codeDirty {
                    Caption(note)
                }
                if let room {
                    Caption(room)
                }
            }
        } foot: {
            HStack(spacing: 8) {
                Word("viewfinder", "Inspect") { browser.toggleInspector() }
                if language == .css {
                    Word("textformat", "Format") { cssDraft = SiteStyles.arranged(cssDraft) }
                }
                Spacer()
                Pill("Save", filled: true) { saveCode() }
                    .disabled(!codeDirty || place == nil)
            }
        }
    }

    private var sitesPlate: some View {
        let others = styles.hosts
            .filter { $0 != place }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return Plate("Other Sites", width: 440, close: close) {
            VStack(alignment: .leading, spacing: 8) {
                Back { pane = .look }
                if others.isEmpty {
                    Card { Nothing("No other sites.") }
                } else {
                    ScrollView(showsIndicators: false) {
                        Card {
                            ForEach(Array(others.enumerated()), id: \.element) { index, host in
                                if index > 0 { Rule() }
                                siteRow(host)
                            }
                        }
                        .padding(.bottom, 2)
                    }
                    .frame(maxHeight: 320)
                }
            }
        }
    }

    private var useRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Card {
                HStack(spacing: 10) {
                    Image(systemName: "power")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(look.on ? Palette.ink : Palette.muted)
                        .frame(width: 22)
                    Text("Use on this site")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink)
                    Spacer(minLength: 8)
                    Switch(on: Binding(
                        get: { look.on },
                        set: { on in
                            guard let host = place else { return }
                            styles.setOn(on, host: host)
                        }
                    ))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
            if !look.on, !look.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Caption("Paused. Turn it on, and JavaScript runs the next time this page loads.")
            }
        }
    }

    private var colors: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "eyedropper")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                Caption("Color")
            }
            HStack(spacing: 8) {
                swatch("Text", hex: look.text) { value in
                    guard let host = place else { return }
                    styles.revise(on: host) { $0.text = value }
                }
                swatch("Background", hex: look.background) { value in
                    guard let host = place else { return }
                    styles.revise(on: host) { $0.background = value }
                }
            }
        }
    }

    private func swatch(_ title: String, hex: String?, pick: @escaping (String?) -> Void) -> some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                ColorWell(label: title, hex: hex) { pick($0) }
                    .frame(width: 44, height: 44)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
                    .overlay {
                        if hex == nil {
                            Image(systemName: "eyedropper")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Palette.muted)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if hex != nil {
                            Image(systemName: "eyedropper")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Palette.ink)
                                .frame(width: 16, height: 16)
                                .background(Palette.ground, in: Circle())
                                .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
                                .offset(x: -4, y: 4)
                                .allowsHitTesting(false)
                        }
                    }
                if hex != nil {
                    Button { pick(nil) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Palette.ink)
                            .frame(width: 16, height: 16)
                            .background(Palette.ground, in: Circle())
                            .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 4, y: -4)
                    .accessibilityLabel("Default")
                    .help("Use the site's own color")
                }
            }
            .frame(height: 48)
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var faces: some View {
        let chosen = look.font
        var names = SiteStyles.faces
        if let chosen, !names.contains(chosen) { names.append(chosen) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Caption("Font")
                Spacer()
                Text(chosen ?? "Default")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    faceTile("Default", nil, selected: chosen == nil)
                    ForEach(names, id: \.self) { name in
                        faceTile(name, name, selected: chosen == name)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func faceTile(_ title: String, _ face: String?, selected: Bool) -> some View {
        Button {
            guard let host = place else { return }
            styles.revise(on: host) { $0.font = face }
        } label: {
            Text("Aa")
                .font(sampleFont(face))
                .foregroundStyle(selected ? Palette.ground : Palette.ink)
                .frame(width: 64, height: 52)
                .background(selected ? Palette.ink : Palette.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? .clear : Palette.hairline, lineWidth: 1)
                )
        }
        .buttonStyle(Press())
        .accessibilityLabel(title)
        .help(title)
        .animation(Motion.settle, value: selected)
    }

    private func sampleFont(_ face: String?) -> Font {
        guard let face,
              let font = NSFontManager.shared.font(withFamily: face, traits: [], weight: 5, size: 22)
        else { return .system(size: 22, weight: .medium) }
        return Font(font)
    }

    private var typeCard: some View {
        Card {
            HStack(spacing: 10) {
                Image(systemName: "textformat.size")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 22)
                Text("Text size")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 8)
                Steps(
                    stops: [80, 90, 100, 110, 125, 150, 175],
                    value: Binding(
                        get: { Double(look.size) },
                        set: { value in
                            guard let host = place else { return }
                            styles.revise(on: host) { $0.size = Int(value.rounded()) }
                        }
                    ),
                    home: 100,
                    label: { "\(Int($0.rounded()))%" }
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            Rule()
            VStack(alignment: .leading, spacing: 8) {
                Text("Capitalization")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                HStack(spacing: 6) {
                    caseButton("Ag", .same, "Default", smallCaps: false)
                    caseButton("AG", .upper, "Uppercase", smallCaps: false)
                    caseButton("ag", .lower, "Lowercase", smallCaps: false)
                    caseButton("Ag", .smallCaps, "Small Caps", smallCaps: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }

    private func caseButton(_ title: String, _ letters: SiteLook.Letters, _ help: String, smallCaps: Bool) -> some View {
        let selected = look.letters == letters
        return Button {
            guard let host = place else { return }
            styles.revise(on: host) { $0.letters = letters }
        } label: {
                Text(title)
                    .font(smallCaps ? .system(size: 13, weight: .semibold).smallCaps() : .system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? Palette.ground : Palette.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(selected ? Palette.ink : Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(Press())
        .accessibilityLabel(help)
        .help(help)
        .animation(Motion.settle, value: selected)
    }

    private var renameField: some View {
        Card {
            HStack(spacing: 8) {
                TextField("Name", text: $nameDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit { commitName() }
                Quick("Done") { commitName() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }

    private var moreMenu: some View {
        Menu {
            Button {
                nameDraft = look.name
                renaming = true
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
            .disabled(place == nil)
            Button {
                guard let host = place else { return }
                styles.setOn(!look.on, host: host)
            } label: {
                Label(look.on ? "Turn Off" : "Turn On", systemImage: "power")
            }
            .disabled(look.isBlank)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More")
        .help("More")
    }

    private func siteRow(_ host: String) -> some View {
        let stored = styles.look(on: host)
        let title = stored.name.isEmpty ? host : stored.name
        let mark = String(title.prefix(1)).uppercased()
        return HStack(spacing: 10) {
            Text(mark)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(width: 26, height: 26)
                .background(Palette.wash, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                if !stored.name.isEmpty {
                    Text(host)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Mark("trash", "Delete") { styles.remove(on: host) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func close() {
        stopHiding()
        browser.styling = false
    }

    /// Leaving the page, or closing the panel, ends picking. A click on the
    /// page is for hiding only while Hide Elements is on.
    private func stopHiding() {
        browser.stopPeeking()
        if browser.veiling { browser.toggleHiding() }
    }

    /// Words still in the editor, not in the file.
    private func warnIfUnsaved() {
        guard !mentioned, let shown else { return }
        let previous = styles.look(on: shown)
        let cssSame = SiteStyles.arranged(cssDraft) == SiteStyles.arranged(previous.css)
        let scriptSame = scriptDraft.trimmingCharacters(in: .whitespacesAndNewlines) == previous.script
        if !cssSame || !scriptSame {
            mentioned = true
            browser.announce("Changes to \(shown) weren't saved.")
        }
    }

    /// A reload keeps this look. No address for a moment is still this
    /// site, so the words stay. Only a different website loads its own,
    /// and words you hadn't saved are left behind.
    private func show(_ host: String?) {
        guard let host, host != shown else { return }
        if shown != nil { stopHiding() }
        keepName()
        warnIfUnsaved()
        mentioned = false
        shown = host
        let next = styles.look(on: host)
        cssDraft = SiteStyles.arranged(next.css)
        scriptDraft = next.script
        nameDraft = next.name
        renaming = false
        note = nil
    }

    private func commitName() {
        guard let host = place else { return }
        styles.revise(on: host) { $0.name = nameDraft }
        renaming = false
    }

    /// A name typed and not confirmed still belongs to the site on screen.
    /// Leaving for another site would otherwise drop it.
    private func keepName() {
        guard renaming, let shown else { return }
        styles.revise(on: shown) { $0.name = nameDraft }
        renaming = false
    }

    private func saveCode() {
        guard let host = place else { return }
        let before = look.script
        let typed = scriptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let scriptCut = SiteStyles.keptScript(scriptDraft).count < typed.count
        let cleaned = styles.keepCode(css: cssDraft, script: scriptDraft, on: host)
        let kept = styles.look(on: host)
        cssDraft = kept.css
        scriptDraft = kept.script
        note = cleaned.fetched ? "A web address was left out."
            : (cleaned.shortened || scriptCut ? "Shortened to fit." : nil)
        let message = savedMessage(cleaned, scriptCut: scriptCut, emptied: kept.isBlank)
        let next = kept.script.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = before.trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = next != previous
        guard SiteStyles.on, kept.on, changed, !next.isEmpty else {
            browser.announce(message)
            return
        }
        fault = nil
        styles.run(next, on: host, watched: tab) { trouble in
            if let trouble {
                fault = trouble.line > 0 ? trouble.line : nil
                browser.announce(trouble.words)
            } else {
                browser.announce(message)
            }
        }
    }

    /// Said only as the text nears the length that gets cut on save.
    private var room: String? {
        let count = (language == .css ? cssDraft : scriptDraft).count
        let left = SiteStyles.limit - count
        if left < 0 { return "Shortened to fit when you save." }
        if left < 4_000 { return "\(left.formatted()) characters left." }
        return nil
    }

    private func savedMessage(_ cleaned: SiteStyles.Cleaned, scriptCut: Bool, emptied: Bool) -> String {
        if cleaned.fetched, cleaned.css.isEmpty { return "A web address was left out." }
        if cleaned.fetched { return "Saved. A web address was left out." }
        if cleaned.shortened || scriptCut { return "Saved. Shortened." }
        if emptied { return "Removed" }
        return "Saved"
    }

    private func reset() {
        guard let host = place else { return }
        styles.reset(on: host)
        cssDraft = ""
        scriptDraft = ""
        renaming = false
        note = nil
        browser.announce("Reset")
    }

    private func remove() {
        guard let host = place else { return }
        styles.remove(on: host)
        cssDraft = ""
        scriptDraft = ""
        nameDraft = ""
        renaming = false
        note = nil
        browser.announce("Removed")
    }

    private func export() {
        guard let host = place, !look.isBlank else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(host).json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(look) else { return }
        do { try data.write(to: url) }
        catch { browser.announce("Couldn't save that file.") }
    }

    private func importFile() {
        guard let host = place else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url),
              let look = try? JSONDecoder().decode(SiteLook.self, from: data) else {
            browser.announce("Couldn't read that file.")
            return
        }
        warnIfUnsaved()
        let script = SiteStyles.keptScript(look.script)
        styles.replace(look, on: host)
        shown = nil
        show(host)
        guard !script.isEmpty, script != styles.look(on: host).script else { return }
        scriptDraft = script
        language = .javaScript
        pane = .code
        browser.announce("Read the JavaScript, then save it.")
    }

    /// What this site has taken off the page. Resting on a line outlines that
    /// thing so you can tell the rows apart. The icon puts it back.
    private var hidden: some View {
        let list = curtain.veils(on: browser.hereHost)
        return Group {
            if !list.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Caption("Hidden on this site. Rest on a line to see it.")
                    ScrollView(showsIndicators: false) {
                        Card {
                            ForEach(Array(list.enumerated()), id: \.element.id) { index, veil in
                                if index > 0 { Rule() }
                                HiddenLine(veil: veil) {
                                    browser.peek(veil)
                                } restore: {
                                    browser.stopPeeking()
                                    browser.restore(veil)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                }
                .onHover { inside in
                    if !inside { browser.stopPeeking() }
                }
            }
        }
    }

    /// A row that opens something else. The icon is what you press it for.
    /// `on` is the mode you are already in, such as hiding things on the page.
    private struct Go: View {
        let icon: String
        let title: String
        var on = false
        let act: () -> Void
        @State private var hovering = false

        init(_ icon: String, _ title: String, on: Bool = false, act: @escaping () -> Void) {
            self.icon = icon
            self.title = title
            self.on = on
            self.act = act
        }

        var body: some View {
            Button(action: act) {
                HStack(spacing: 10) {
                    Image(systemName: on ? "\(icon).fill" : icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(on ? Palette.ground : Palette.ink)
                        .frame(width: 22)
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(on ? Palette.ground : Palette.ink)
                    Spacer(minLength: 8)
                    if !on {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.faint)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(on ? Palette.ink : (hovering ? Palette.hover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
            .animation(Motion.quick, value: on)
        }
    }

    /// One hidden thing. The icon at the end puts it back on the page.
    private struct HiddenLine: View {
        let veil: Veil
        let peek: () -> Void
        let restore: () -> Void
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(veil.label)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    if let note = veil.note, !note.isEmpty {
                        Text(note)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Button(action: restore) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(hovering ? Palette.ink : Palette.muted)
                        .frame(width: 22, height: 22)
                        .background(Palette.wash, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show")
                .help("Show")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(hovering ? Palette.hover : .clear)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { peek() }
            }
            .animation(Motion.quick, value: hovering)
        }
    }

    /// A word with an icon, for the code page.
    private struct Word: View {
        let icon: String
        let title: String
        let act: () -> Void
        @State private var hovering = false

        init(_ icon: String, _ title: String, act: @escaping () -> Void) {
            self.icon = icon
            self.title = title
            self.act = act
        }

        var body: some View {
            Button(action: act) {
                HStack(spacing: 5) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                    Text(title)
                        .font(.system(size: 11.5))
                }
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(hovering ? Palette.hover : Palette.ground, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }

    /// One icon, named for when the pointer rests on it.
    private struct Mark: View {
        let icon: String
        let help: String
        var enabled = true
        let act: () -> Void
        @State private var hovering = false

        init(_ icon: String, _ help: String, enabled: Bool = true, act: @escaping () -> Void) {
            self.icon = icon
            self.help = help
            self.enabled = enabled
            self.act = act
        }

        var body: some View {
            Button(action: act) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(enabled ? (hovering ? Palette.ink : Palette.muted) : Palette.faint)
                    .frame(width: 28, height: 28)
                    .background(hovering && enabled ? Palette.hover : .clear, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(Press())
            .disabled(!enabled)
            .help(help)
            .accessibilityLabel(help)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }

    /// A press settles a little, so a choice feels taken.
    private struct Press: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !Motion.reduced ? 0.96 : 1)
                .animation(Motion.quick, value: configuration.isPressed)
        }
    }

    private struct Back: View {
        let act: () -> Void
        var body: some View {
            Button(action: act) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.muted)
            }
            .buttonStyle(.plain)
        }
    }
}

/// The system color well, kept to a hex so the sheet only ever holds a color.
private struct ColorWell: NSViewRepresentable {
    var label: String
    var hex: String?
    var pick: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(pick: pick) }

    func makeNSView(context: Context) -> NSColorWell {
        let well = NSColorWell()
        well.color = SiteStyles.color(hex) ?? .controlBackgroundColor
        well.target = context.coordinator
        well.action = #selector(Coordinator.changed(_:))
        well.setAccessibilityLabel(label)
        context.coordinator.shown = hex
        return well
    }

    func updateNSView(_ well: NSColorWell, context: Context) {
        context.coordinator.pick = pick
        guard context.coordinator.shown != hex else { return }
        context.coordinator.shown = hex
        context.coordinator.quiet = true
        well.color = SiteStyles.color(hex) ?? .controlBackgroundColor
        context.coordinator.quiet = false
    }

    final class Coordinator: NSObject {
        var pick: (String) -> Void
        var shown: String?
        var quiet = false
        init(pick: @escaping (String) -> Void) { self.pick = pick }
        @objc func changed(_ well: NSColorWell) {
            MainActor.assumeIsolated {
                guard !quiet, let hex = SiteStyles.hex(of: well.color) else { return }
                shown = hex
                pick(hex)
            }
        }
    }
}

/// Colors for the code field. Drawn over the text, never written into it,
/// so a paste and a save stay the characters you typed. A color code wears
/// its own color. A `#` that starts a selector does not: that is a name.
enum CodeTint {
    struct Mark: Equatable {
        var location: Int
        var length: Int
        var kind: Kind
    }

    enum Kind: Equatable {
        case comment, string, keyword, number
        case color(UInt8, UInt8, UInt8, UInt8)
    }

    private static let words: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const", "continue",
        "default", "delete", "do", "else", "export", "extends", "false", "finally",
        "for", "function", "if", "import", "in", "instanceof", "let", "new", "null",
        "of", "return", "static", "super", "switch", "this", "throw", "true", "try",
        "typeof", "undefined", "var", "while", "yield"
    ]
    private static let units: Set<String> = [
        "px", "em", "rem", "vh", "vw", "vmin", "vmax", "ch", "ex", "pt", "pc",
        "in", "cm", "mm", "s", "ms", "deg", "turn", "fr", "dvh", "dvw"
    ]

    static func marks(_ text: String, script: Bool) -> [Mark] {
        let source = text as NSString
        let n = source.length
        var marks: [Mark] = []
        var i = 0
        while i < n {
            let c = source.character(at: i)
            if c == 34 || c == 39 || c == 96 {
                let start = i
                i = endOfString(source, from: i, quote: c)
                marks.append(Mark(location: start, length: i - start, kind: .string))
                appendHex(source, into: &marks, from: start, to: i, trusted: true)
                continue
            }
            if c == 47, i + 1 < n, source.character(at: i + 1) == 42 {
                let start = i
                i = endOfComment(source, from: i + 2)
                marks.append(Mark(location: start, length: i - start, kind: .comment))
                continue
            }
            if script, c == 47, i + 1 < n, source.character(at: i + 1) == 47 {
                let start = i
                i += 2
                while i < n, source.character(at: i) != 10 { i += 1 }
                marks.append(Mark(location: start, length: i - start, kind: .comment))
                continue
            }
            if c == 35, let found = hexColor(source, at: i, trusted: false) {
                marks.append(Mark(location: i, length: found.end - i, kind: .color(found.r, found.g, found.b, found.a)))
                i = found.end
                continue
            }
            if !script, c == 64 {
                let (word, end) = readIdent(source, from: i + 1)
                if !word.isEmpty {
                    marks.append(Mark(location: i, length: end - i, kind: .keyword))
                    i = end
                    continue
                }
            }
            if !script, c == 33 {
                let (word, end) = readIdent(source, from: i + 1)
                if word.lowercased() == "important" {
                    marks.append(Mark(location: i, length: end - i, kind: .keyword))
                    i = end
                    continue
                }
            }
            if isDigit(c) || (c == 46 && i + 1 < n && isDigit(source.character(at: i + 1))),
               i == 0 || !isIdent(source.character(at: i - 1)),
               let end = readNumber(source, from: i, script: script), end > i {
                marks.append(Mark(location: i, length: end - i, kind: .number))
                i = end
                continue
            }
            if isIdentStart(c) {
                if !script, let found = colorCall(source, at: i) {
                    marks.append(Mark(location: i, length: found.end - i, kind: .color(found.r, found.g, found.b, found.a)))
                    i = found.end
                    continue
                }
                let (word, end) = readIdent(source, from: i)
                if end == i { i += 1; continue }
                if script, words.contains(word) {
                    marks.append(Mark(location: i, length: end - i, kind: .keyword))
                }
                i = end
                continue
            }
            i += 1
        }
        return marks
    }

    /// The bracket beside the caret, and the one that closes it. Nothing
    /// while the caret is in a string or a comment, where a brace is text.
    static func pair(in text: String, caret: Int, script: Bool) -> (Int, Int)? {
        let source = text as NSString
        let n = source.length
        guard caret >= 0, caret <= n else { return nil }
        let spots = [caret - 1, caret].filter { $0 >= 0 && $0 < n }
        let openers: [unichar: unichar] = [40: 41, 91: 93, 123: 125]
        let closers: Set<unichar> = [41, 93, 125]
        guard let target = spots.first(where: { openers[source.character(at: $0)] != nil || closers.contains(source.character(at: $0)) }) else {
            return nil
        }
        var stack: [(unichar, Int)] = []
        var i = 0
        var quote: unichar = 0
        var block = false
        var line = false
        while i < n {
            let c = source.character(at: i)
            if block {
                if c == 42, i + 1 < n, source.character(at: i + 1) == 47 { block = false; i += 2 }
                else { i += 1 }
                continue
            }
            if line {
                if c == 10 { line = false }
                i += 1
                continue
            }
            if quote != 0 {
                if c == 92 { i = min(i + 2, n); continue }
                if c == quote || (quote != 96 && c == 10) { quote = 0 }
                i += 1
                continue
            }
            if c == 34 || c == 39 || c == 96 { quote = c; i += 1; continue }
            if c == 47, i + 1 < n, source.character(at: i + 1) == 42 { block = true; i += 2; continue }
            if script, c == 47, i + 1 < n, source.character(at: i + 1) == 47 { line = true; i += 2; continue }
            if let closer = openers[c] {
                stack.append((closer, i))
            } else if closers.contains(c), let last = stack.last, last.0 == c {
                stack.removeLast()
                if last.1 == target || i == target { return (last.1, i) }
            }
            i += 1
        }
        return nil
    }

    /// Ink that stays readable on the color, blended over the field so a
    /// transparent color doesn't turn the letters white on white.
    static func chip(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> (ink: NSColor, wash: NSColor) {
        func mix(_ appearance: NSAppearance) -> (CGFloat, CGFloat, CGFloat) {
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let base: CGFloat = dark ? 0.175 : 0.937
            let alpha = CGFloat(a) / 255
            return (
                CGFloat(r) / 255 * alpha + base * (1 - alpha),
                CGFloat(g) / 255 * alpha + base * (1 - alpha),
                CGFloat(b) / 255 * alpha + base * (1 - alpha)
            )
        }
        let wash = NSColor(name: nil, dynamicProvider: { appearance in
            let (cr, cg, cb) = mix(appearance)
            return NSColor(srgbRed: cr, green: cg, blue: cb, alpha: 1)
        })
        let ink = NSColor(name: nil, dynamicProvider: { appearance in
            let (cr, cg, cb) = mix(appearance)
            let light = 0.2126 * cr + 0.7152 * cg + 0.0722 * cb
            return light > 0.62
                ? NSColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1)
                : NSColor(srgbRed: 0.98, green: 0.98, blue: 0.98, alpha: 1)
        })
        return (ink, wash)
    }

    private static func appendHex(_ source: NSString, into marks: inout [Mark], from: Int, to: Int, trusted: Bool) {
        var j = from
        while j < to {
            if source.character(at: j) == 35, let found = hexColor(source, at: j, trusted: trusted), found.end <= to {
                marks.append(Mark(location: j, length: found.end - j, kind: .color(found.r, found.g, found.b, found.a)))
                j = found.end
            } else {
                j += 1
            }
        }
    }

    /// A value, not a selector. `#header` at the start of a rule is a name.
    /// `#fff` after a colon, or inside `rgb` and `linear-gradient`, is a color.
    private static func inValue(_ source: NSString, before start: Int) -> Bool {
        var j = start - 1
        var depth = 0
        while j >= 0 {
            let c = source.character(at: j)
            if c == 41 { depth += 1 }
            else if c == 40 {
                if depth == 0 { return true }
                depth -= 1
            } else if depth == 0, c == 58 {
                return true
            } else if depth == 0, c == 59 || c == 123 || c == 125 {
                return false
            }
            j -= 1
        }
        return false
    }

    private static func hexColor(_ source: NSString, at start: Int, trusted: Bool) -> (end: Int, r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        let n = source.length
        guard start < n, source.character(at: start) == 35 else { return nil }
        var i = start + 1
        let digits = i
        while i < n, isHex(source.character(at: i)) { i += 1 }
        let count = i - digits
        guard count == 3 || count == 4 || count == 6 || count == 8 else { return nil }
        if !trusted, !inValue(source, before: start) { return nil }
        let raw = source.substring(with: NSRange(location: digits, length: count))
        guard let rgba = expandHex(raw) else { return nil }
        return (i, rgba.0, rgba.1, rgba.2, rgba.3)
    }

    private static func expandHex(_ raw: String) -> (UInt8, UInt8, UInt8, UInt8)? {
        let chars = Array(raw)
        let full: [Character]
        switch chars.count {
        case 3: full = chars.flatMap { [$0, $0] } + ["f", "f"]
        case 4: full = chars.flatMap { [$0, $0] }
        case 6: full = chars + ["f", "f"]
        case 8: full = chars
        default: return nil
        }
        func byte(_ index: Int) -> UInt8? {
            guard let hi = nibble(full[index]), let lo = nibble(full[index + 1]) else { return nil }
            return hi << 4 | lo
        }
        guard let r = byte(0), let g = byte(2), let b = byte(4), let a = byte(6) else { return nil }
        return (r, g, b, a)
    }

    private static func nibble(_ c: Character) -> UInt8? {
        guard let v = c.asciiValue else { return nil }
        switch v {
        case 48...57: return v - 48
        case 65...70: return v - 55
        case 97...102: return v - 87
        default: return nil
        }
    }

    private static func colorCall(_ source: NSString, at start: Int) -> (end: Int, r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        let n = source.length
        if start > 0, isIdent(source.character(at: start - 1)) { return nil }
        let (name, after) = readIdent(source, from: start)
        let kind = name.lowercased()
        let hsl = kind == "hsl" || kind == "hsla"
        guard hsl || kind == "rgb" || kind == "rgba" else { return nil }
        guard after < n, source.character(at: after) == 40 else { return nil }
        var i = after + 1
        func skip() {
            while i < n {
                let c = source.character(at: i)
                if c == 32 || c == 9 || c == 10 || c == 13 { i += 1 } else { break }
            }
        }
        func number() -> (Double, Bool)? {
            skip()
            let begin = i
            if i < n, source.character(at: i) == 43 || source.character(at: i) == 45 { i += 1 }
            let mark = i
            while i < n, isDigit(source.character(at: i)) { i += 1 }
            if i < n, source.character(at: i) == 46 {
                i += 1
                while i < n, isDigit(source.character(at: i)) { i += 1 }
            }
            if i == mark { i = begin; return nil }
            let raw = source.substring(with: NSRange(location: begin, length: i - begin))
            guard let value = Double(raw) else { i = begin; return nil }
            skip()
            var percent = false
            if i < n, source.character(at: i) == 37 { percent = true; i += 1 }
            return (value, percent)
        }
        func comma() {
            skip()
            if i < n, source.character(at: i) == 44 { i += 1 }
        }
        guard let first = number() else { return nil }
        if hsl {
            skip()
            if has(source, at: i, "deg") { i += 3 }
        }
        comma()
        guard let second = number() else { return nil }
        comma()
        guard let third = number() else { return nil }
        var alpha = 1.0
        skip()
        if i < n, source.character(at: i) == 44 || source.character(at: i) == 47 {
            i += 1
            if let part = number() {
                alpha = part.1 ? part.0 / 100 : (part.0 > 1 ? part.0 / 255 : part.0)
            }
        }
        skip()
        guard i < n, source.character(at: i) == 41 else { return nil }
        i += 1
        alpha = min(1, max(0, alpha))
        func byte(_ value: Double) -> UInt8 {
            UInt8(min(255, max(0, Int(value.rounded()))))
        }
        if hsl {
            let hue = first.1 ? first.0 / 100 * 360 : first.0
            let sat = second.1 ? second.0 / 100 : (second.0 > 1 ? second.0 / 100 : second.0)
            let lig = third.1 ? third.0 / 100 : (third.0 > 1 ? third.0 / 100 : third.0)
            let (r, g, b) = hslToRGB(hue, min(1, max(0, sat)), min(1, max(0, lig)))
            return (i, r, g, b, byte(alpha * 255))
        }
        func channel(_ part: (Double, Bool)) -> UInt8 {
            byte(part.1 ? part.0 / 100 * 255 : part.0)
        }
        return (i, channel(first), channel(second), channel(third), byte(alpha * 255))
    }

    private static func hslToRGB(_ h: Double, _ s: Double, _ l: Double) -> (UInt8, UInt8, UInt8) {
        let hue = ((h.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) / 360
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func channel(_ t0: Double) -> UInt8 {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            let v: Double
            if t < 1.0 / 6 { v = p + (q - p) * 6 * t }
            else if t < 0.5 { v = q }
            else if t < 2.0 / 3 { v = p + (q - p) * (2.0 / 3 - t) * 6 }
            else { v = p }
            return UInt8(min(255, max(0, Int((v * 255).rounded()))))
        }
        return (channel(hue + 1.0 / 3), channel(hue), channel(hue - 1.0 / 3))
    }

    private static func has(_ source: NSString, at i: Int, _ word: String) -> Bool {
        let len = (word as NSString).length
        guard i >= 0, i + len <= source.length else { return false }
        return source.substring(with: NSRange(location: i, length: len)).lowercased() == word
    }

    private static func endOfString(_ source: NSString, from start: Int, quote: unichar) -> Int {
        let n = source.length
        var i = start + 1
        while i < n {
            let next = source.character(at: i)
            if next == 92 { i = min(i + 2, n); continue }
            i += 1
            if next == quote || (quote != 96 && next == 10) { break }
        }
        return i
    }

    private static func endOfComment(_ source: NSString, from start: Int) -> Int {
        let n = source.length
        var i = start
        while i + 1 < n {
            if source.character(at: i) == 42, source.character(at: i + 1) == 47 { return i + 2 }
            i += 1
        }
        return n
    }

    private static func readIdent(_ source: NSString, from start: Int) -> (String, Int) {
        var i = start
        while i < source.length, isIdent(source.character(at: i)) { i += 1 }
        guard i > start else { return ("", start) }
        return (source.substring(with: NSRange(location: start, length: i - start)), i)
    }

    private static func readNumber(_ source: NSString, from start: Int, script: Bool) -> Int? {
        let n = source.length
        var i = start
        var saw = false
        if i < n, isDigit(source.character(at: i)) {
            saw = true
            while i < n, isDigit(source.character(at: i)) { i += 1 }
        }
        if i < n, source.character(at: i) == 46 {
            let dot = i
            i += 1
            if i < n, isDigit(source.character(at: i)) {
                saw = true
                while i < n, isDigit(source.character(at: i)) { i += 1 }
            } else {
                i = dot
            }
        }
        guard saw else { return nil }
        if i < n, source.character(at: i) == 101 || source.character(at: i) == 69 {
            var j = i + 1
            if j < n, source.character(at: j) == 43 || source.character(at: j) == 45 { j += 1 }
            let exp = j
            while j < n, isDigit(source.character(at: j)) { j += 1 }
            if j > exp { i = j }
        }
        if !script {
            if i < n, source.character(at: i) == 37 { i += 1 }
            else if i < n, isIdentStart(source.character(at: i)) {
                let (word, end) = readIdent(source, from: i)
                if units.contains(word.lowercased()) { i = end }
            }
        }
        return i
    }

    private static func isDigit(_ c: unichar) -> Bool { c >= 48 && c <= 57 }
    private static func isHex(_ c: unichar) -> Bool {
        isDigit(c) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102)
    }
    private static func isIdentStart(_ c: unichar) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36
    }
    private static func isIdent(_ c: unichar) -> Bool { isIdentStart(c) || isDigit(c) }
}

/// A code field. Wrapping is on, and the substitutions that turn a quote
/// into a curly one are off, so what you save is what you typed.
private struct CodeView: NSViewRepresentable {
    @Binding var text: String
    var kind: CodeKind
    @Binding var fault: Int?

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, fault: $fault, kind: kind) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.delegate = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isEditable = true
        view.isSelectable = true
        view.drawsBackground = false
        view.usesFontPanel = false
        view.usesFindPanel = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.isAutomaticTextCompletionEnabled = false
        view.smartInsertDeleteEnabled = false
        view.enabledTextCheckingTypes = 0
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.lineBreakMode = .byCharWrapping
        view.string = text
        context.coordinator.paint(view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        context.coordinator.fault = $fault
        context.coordinator.kind = kind
        if view.string != text {
            let range = view.selectedRange()
            view.string = text
            let end = (text as NSString).length
            view.setSelectedRange(NSRange(location: min(range.location, end), length: 0))
        }
        if context.coordinator.shown != fault {
            context.coordinator.shown = fault
            if let fault { context.coordinator.show(fault, in: view) }
        }
        context.coordinator.paint(view)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var fault: Binding<Int?>
        var kind: CodeKind
        var shown: Int?
        init(text: Binding<String>, fault: Binding<Int?>, kind: CodeKind) {
            self.text = text
            self.fault = fault
            self.kind = kind
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if fault.wrappedValue != nil { fault.wrappedValue = nil }
            text.wrappedValue = view.string
            paint(view)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            paint(view)
        }

        /// Tab indents by the same two spaces Format uses. Shift-tab takes
        /// them back. Return keeps the line's indent, and steps in after a brace.
        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertTab(_:)) {
                indent(view, by: 2)
                return true
            }
            if selector == #selector(NSResponder.insertBacktab(_:)) {
                indent(view, by: -2)
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                view.insertText(newline(in: view), replacementRange: view.selectedRange())
                return true
            }
            return false
        }

        /// A closing brace on an otherwise empty indent steps back out.
        func textView(_ view: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
            guard text == "}", range.length == 0 else { return true }
            let ns = view.string as NSString
            let line = ns.lineRange(for: range)
            let before = ns.substring(with: NSRange(location: line.location, length: range.location - line.location))
            guard before.count >= 2, before.allSatisfy({ $0 == " " }) else { return true }
            view.insertText("}", replacementRange: NSRange(location: range.location - 2, length: 2))
            return false
        }

        func show(_ line: Int, in view: NSTextView) {
            guard line > 0 else { return }
            let ns = view.string as NSString
            var at = 0
            var left = line
            while left > 1, at < ns.length {
                let range = ns.lineRange(for: NSRange(location: at, length: 0))
                let next = range.location + range.length
                if next <= at { break }
                at = next
                left -= 1
            }
            let spot = min(at, ns.length)
            view.setSelectedRange(NSRange(location: spot, length: 0))
            view.scrollRangeToVisible(NSRange(location: spot, length: 0))
        }

        /// Colors and the matching bracket. Temporary, so the text stays plain.
        func paint(_ view: NSTextView) {
            guard let layout = view.layoutManager, let storage = view.textStorage else { return }
            let whole = NSRange(location: 0, length: storage.length)
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)
            let comment = NSColor.tertiaryLabelColor
            let string = NSColor.systemRed
            let keyword = NSColor.systemBlue
            let number = NSColor.systemTeal
            let script = kind == .javaScript
            for mark in CodeTint.marks(storage.string, script: script) {
                let range = NSRange(location: mark.location, length: mark.length)
                guard range.location + range.length <= storage.length else { continue }
                switch mark.kind {
                case .comment:
                    layout.addTemporaryAttribute(.foregroundColor, value: comment, forCharacterRange: range)
                case .string:
                    layout.addTemporaryAttribute(.foregroundColor, value: string, forCharacterRange: range)
                case .keyword:
                    layout.addTemporaryAttribute(.foregroundColor, value: keyword, forCharacterRange: range)
                case .number:
                    layout.addTemporaryAttribute(.foregroundColor, value: number, forCharacterRange: range)
                case .color(let r, let g, let b, let a):
                    let chip = CodeTint.chip(r, g, b, a)
                    layout.addTemporaryAttribute(.foregroundColor, value: chip.ink, forCharacterRange: range)
                    layout.addTemporaryAttribute(.backgroundColor, value: chip.wash, forCharacterRange: range)
                }
            }
            let caret = view.selectedRange()
            if caret.length == 0, let (open, close) = CodeTint.pair(in: storage.string, caret: caret.location, script: script) {
                let wash = NSColor.labelColor.withAlphaComponent(0.12)
                for at in [open, close] where at >= 0 && at < storage.length {
                    layout.addTemporaryAttribute(.backgroundColor, value: wash, forCharacterRange: NSRange(location: at, length: 1))
                }
            }
        }

        private func newline(in view: NSTextView) -> String {
            let ns = view.string as NSString
            let caret = view.selectedRange().location
            let line = ns.lineRange(for: NSRange(location: min(caret, ns.length), length: 0))
            let prefix = ns.substring(with: NSRange(location: line.location, length: max(0, caret - line.location)))
            var spaces = ""
            for character in prefix {
                if character == " " { spaces.append(" ") } else { break }
            }
            let trimmed = prefix.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix("{") || trimmed.hasSuffix("(") || trimmed.hasSuffix("[") {
                spaces += "  "
            }
            return "\n" + spaces
        }

        private func indent(_ view: NSTextView, by spaces: Int) {
            let ns = view.string as NSString
            let sel = view.selectedRange()
            if sel.length == 0 {
                if spaces > 0 {
                    view.insertText(String(repeating: " ", count: spaces), replacementRange: sel)
                } else {
                    let start = max(0, sel.location - 2)
                    let chunk = ns.substring(with: NSRange(location: start, length: sel.location - start))
                    let drop = chunk.reversed().prefix { $0 == " " }.count
                    guard drop > 0 else { return }
                    view.insertText("", replacementRange: NSRange(location: sel.location - drop, length: drop))
                }
                return
            }
            let block = ns.lineRange(for: sel)
            var lines: [NSRange] = []
            var at = block.location
            let end = block.location + block.length
            while at < end {
                let line = ns.lineRange(for: NSRange(location: at, length: 0))
                lines.append(line)
                let next = line.location + line.length
                if next <= at { break }
                at = next
            }
            view.undoManager?.beginUndoGrouping()
            for line in lines.reversed() {
                if spaces > 0 {
                    view.insertText("  ", replacementRange: NSRange(location: line.location, length: 0))
                } else {
                    let text = ns.substring(with: line)
                    var count = 0
                    for character in text {
                        if character == " ", count < 2 { count += 1 } else { break }
                    }
                    if count > 0 {
                        view.insertText("", replacementRange: NSRange(location: line.location, length: count))
                    }
                }
            }
            view.undoManager?.endUndoGrouping()
        }
    }
}
