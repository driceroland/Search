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
// the panel keeps them; there is no account and nothing is sent anywhere.
//
// The first version of the file stored a site's CSS as a string. That still
// reads, as a look with only that CSS.
//
// CSS is put in as text, so it can't close the style element and run as
// script. An imported sheet, or a web address in url(), is left out: either
// one would fetch from somewhere else, and Search doesn't fetch on a page's
// behalf except the page you asked for. Laying the CSS out never changes
// what that keeps — `clean` is the gate, and `arranged` only adds whitespace.

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
    private var saving = false

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

    /// The CSS and JavaScript, after anything that would fetch has been taken
    /// out of the CSS. A look with nothing left is forgotten.
    @discardableResult
    func keepCode(css raw: String, script rawScript: String, on host: String) -> Cleaned {
        var look = byHost[host] ?? SiteLook()
        let cleaned = Self.clean(raw)
        look.css = cleaned.css.isEmpty ? "" : Self.arranged(cleaned.css)
        look.script = Self.laidOut(rawScript)
        store(look, on: host)
        applyOpen()
        return cleaned
    }

    /// A look read from a file you picked. Its CSS goes through the same
    /// gate as CSS you typed. Its JavaScript waits for the next load.
    func replace(_ raw: SiteLook, on host: String) {
        var look = raw
        look.text = Self.hex(look.text)
        look.background = Self.hex(look.background)
        look.font = Self.safeFont(look.font)
        if !(80...200).contains(look.size) { look.size = 100 }
        look.name = String(look.name.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = Self.clean(look.css)
        look.css = cleaned.css.isEmpty ? "" : Self.arranged(cleaned.css)
        look.script = Self.laidOut(look.script)
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
    /// alone: waking one would load it, and the next load arms it.
    func applyOpen() {
        for tab in openTabs {
            guard let web = tab.built, let host = Dusk.host(of: tab.address) else { continue }
            let sheet = Self.on ? (css(on: host) ?? "") : ""
            web.evaluateJavaScript(Veiling.style(sheet, id: Self.element), in: nil, in: Web.world) { _ in }
        }
    }

    /// Runs a site's JavaScript once, on the pages of that site open now.
    /// `watched` is the page whose error, if it has one, is reported.
    func run(_ source: String, on host: String, watched: Tab?, then: @escaping (Bool) -> Void) {
        var watchedRan = false
        for tab in openTabs where Dusk.host(of: tab.address) == host {
            guard let web = tab.built else { continue }
            let watch = tab === watched
            if watch { watchedRan = true }
            web.evaluateJavaScript(source, in: nil, in: .page) { result in
                guard watch else { return }
                let failed: Bool
                if case .failure = result { failed = true } else { failed = false }
                Task { @MainActor in then(failed) }
            }
        }
        if !watchedRan { then(false) }
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
                if character == open { quote = nil }
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

    /// The same JavaScript, with a line for each statement. A string, a
    /// comment, a template and a regular expression are left as they are,
    /// and doing it twice changes nothing. No library: it only walks the
    /// text.
    static func arrangedScript(_ source: String) -> String {
        let chars = Array(source)
        var index = 0
        var out = ""
        var depth = 0
        var paren = 0
        var quote: Character?
        var escaped = false
        var template = false
        var expr = 0
        var lineComment = false
        var blockComment = false

        func indent() -> String { String(repeating: "  ", count: max(depth, 0)) }
        func trimTail() {
            while let last = out.last, last == " " || last == "\t" { out.removeLast() }
        }
        func lastCode() -> Character? {
            for character in out.reversed() where character != " " && character != "\n" && character != "\t" {
                return character
            }
            return nil
        }
        func nextNonSpace(_ from: Int) -> Character? {
            var cursor = from
            while cursor < chars.count, chars[cursor] == " " || chars[cursor] == "\n" || chars[cursor] == "\t" || chars[cursor] == "\r" {
                cursor += 1
            }
            return cursor < chars.count ? chars[cursor] : nil
        }
        func nextWord(_ from: Int) -> String {
            var cursor = from
            while cursor < chars.count, chars[cursor] == " " || chars[cursor] == "\n" || chars[cursor] == "\t" || chars[cursor] == "\r" {
                cursor += 1
            }
            var word = ""
            while cursor < chars.count, chars[cursor].isLetter { word.append(chars[cursor]); cursor += 1 }
            return word
        }
        func canStartRegex(_ previous: Character?) -> Bool {
            guard let previous else { return true }
            if previous.isLetter || previous.isNumber || previous == ")" || previous == "]" { return false }
            return true
        }

        while index < chars.count {
            let character = chars[index]
            if lineComment {
                if character == "\n" {
                    lineComment = false
                    trimTail()
                    out += "\n" + indent()
                } else {
                    out.append(character)
                }
                index += 1
                continue
            }
            if blockComment {
                out.append(character)
                if character == "/", index > 0, chars[index - 1] == "*" { blockComment = false }
                index += 1
                continue
            }
            if let open = quote {
                out.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == open { quote = nil }
                index += 1
                continue
            }
            if template && expr == 0 {
                out.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "`" { template = false }
                else if character == "$", index + 1 < chars.count, chars[index + 1] == "{" {
                    out.append("{")
                    index += 2
                    expr = 1
                    continue
                }
                index += 1
                continue
            }
            if character == "/", index + 1 < chars.count, chars[index + 1] == "/" {
                lineComment = true
                trimTail()
                if let last = out.last, last != "\n" { out.append(" ") }
                out.append(character)
                index += 1
                continue
            }
            if character == "/", index + 1 < chars.count, chars[index + 1] == "*" {
                blockComment = true
                out.append(character)
                index += 1
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                escaped = false
                out.append(character)
                index += 1
                continue
            }
            if character == "`" {
                template = true
                escaped = false
                out.append(character)
                index += 1
                continue
            }
            if character == "/", expr == 0, canStartRegex(lastCode()) {
                out.append(character)
                index += 1
                var slashEscaped = false
                var inClass = false
                while index < chars.count {
                    let token = chars[index]
                    out.append(token)
                    index += 1
                    if slashEscaped { slashEscaped = false; continue }
                    if token == "\\" { slashEscaped = true; continue }
                    if token == "[" { inClass = true }
                    if token == "]" { inClass = false }
                    if token == "/" && !inClass { break }
                    if token == "\n" { break }
                }
                continue
            }
            switch character {
            case "(":
                paren += 1
                out.append(character)
            case ")":
                paren = max(paren - 1, 0)
                out.append(character)
            case "{":
                if expr > 0 {
                    expr += 1
                    out.append(character)
                } else {
                    trimTail()
                    let tight = out.last == "(" || out.last == "}" || out.last == "]"
                    out += (tight ? "" : " ") + "{\n"
                    depth += 1
                    out += indent()
                }
            case "}":
                if expr > 1 {
                    expr -= 1
                    out.append(character)
                } else if expr == 1 {
                    expr = 0
                    out.append(character)
                } else {
                    trimTail()
                    while out.last == "\n" || out.last == " " { out.removeLast() }
                    depth = max(depth - 1, 0)
                    out += "\n" + indent() + "}"
                    let word = nextWord(index + 1)
                    let next = nextNonSpace(index + 1)
                    if word == "else" || word == "catch" || word == "finally" || word == "while" {
                        out += " "
                    } else if next == ";" || next == ")" || next == "," || next == "." || next == "}" {
                    } else if next != nil {
                        out += "\n" + indent()
                    }
                }
            case ";":
                trimTail()
                out.append(";")
                if paren == 0 && expr == 0 {
                    out += "\n" + indent()
                }
            case ",":
                trimTail()
                out.append(",")
                if paren == 0 && expr == 0 && depth > 0 {
                    out += "\n" + indent()
                } else {
                    out.append(" ")
                }
            case "\n", "\r", "\t", " ":
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

    /// Laid out, then cut to `limit` if a pasted library ran past it.
    private static func laidOut(_ raw: String) -> String {
        let arranged = arrangedScript(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard arranged.count > limit else { return arranged }
        return String(arranged.prefix(limit))
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
        guard !saving else { return }
        saving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            saving = false
            let snapshot = byHost
            let file = Self.file
            DispatchQueue.global(qos: .utility).async {
                guard let data = try? JSONEncoder().encode(snapshot) else { return }
                try? FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try? data.write(to: file, options: .atomic)
            }
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
        if let tab = browser.active {
            StyleEditor(browser: browser, tab: tab)
                .id(tab.id)
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
        let scriptSame = SiteStyles.arrangedScript(scriptDraft) == SiteStyles.arrangedScript(look.script)
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
        .onChange(of: site) { _, next in show(next) }
        .onChange(of: pane) { _, next in
            if next != .look { stopHiding() }
        }
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
                CodeView(text: language == .css ? $cssDraft : $scriptDraft, kind: language)
                    .id("\(place ?? "")-\(language.rawValue)")
                    .frame(height: 220)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                if language == .css, let note, !codeDirty {
                    Caption(note)
                }
            }
        } foot: {
            HStack(spacing: 8) {
                Word("viewfinder", "Inspect") { browser.toggleInspector() }
                Word("textformat", "Format") {
                    if language == .css { cssDraft = SiteStyles.arranged(cssDraft) }
                    else { scriptDraft = SiteStyles.arrangedScript(scriptDraft) }
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
                Caption("JavaScript runs the next time this page loads.")
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

    /// A reload keeps this look. No address for a moment is still this
    /// site, so the words stay. Only a different website loads its own,
    /// and words you hadn't saved are left behind.
    private func show(_ host: String?) {
        guard let host, host != shown else { return }
        if shown != nil { stopHiding() }
        if let shown {
            let previous = styles.look(on: shown)
            let cssSame = SiteStyles.arranged(cssDraft) == SiteStyles.arranged(previous.css)
            let scriptSame = SiteStyles.arrangedScript(scriptDraft) == SiteStyles.arrangedScript(previous.script)
            if !cssSame || !scriptSame {
                browser.announce("Changes to \(shown) weren't saved.")
            }
        }
        shown = host
        let next = styles.look(on: host)
        cssDraft = SiteStyles.arranged(next.css)
        scriptDraft = SiteStyles.arrangedScript(next.script)
        nameDraft = next.name
        renaming = false
        note = nil
    }

    private func commitName() {
        guard let host = place else { return }
        styles.revise(on: host) { $0.name = nameDraft }
        renaming = false
    }

    private func saveCode() {
        guard let host = place else { return }
        let before = look.script
        let scriptCut = scriptDraft.count > SiteStyles.limit
        let cleaned = styles.keepCode(css: cssDraft, script: scriptDraft, on: host)
        let kept = styles.look(on: host)
        cssDraft = kept.css
        scriptDraft = kept.script
        note = cleaned.fetched ? "A web address was left out."
            : (cleaned.shortened || scriptCut ? "Shortened to fit." : nil)
        let message = savedMessage(cleaned, scriptCut: scriptCut, emptied: kept.isBlank)
        let next = kept.script.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = before.trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = SiteStyles.arrangedScript(next) != SiteStyles.arrangedScript(previous)
        guard kept.on, changed, !next.isEmpty else {
            browser.announce(message)
            return
        }
        styles.run(next, on: host, watched: tab) { failed in
            browser.announce(failed ? "Saved. The JavaScript has an error." : message)
        }
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
        styles.replace(look, on: host)
        shown = nil
        show(host)
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

/// A code field. Wrapping is on, and the substitutions that turn a quote
/// into a curly one are off, so what you save is what you typed.
private struct CodeView: NSViewRepresentable {
    @Binding var text: String
    var kind: CodeKind

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, kind: kind) }

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
        context.coordinator.kind = kind
        guard view.string != text else {
            context.coordinator.paint(view)
            return
        }
        let range = view.selectedRange()
        view.string = text
        let end = (text as NSString).length
        view.setSelectedRange(NSRange(location: min(range.location, end), length: 0))
        context.coordinator.paint(view)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var kind: CodeKind
        init(text: Binding<String>, kind: CodeKind) {
            self.text = text
            self.kind = kind
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
            paint(view)
        }

        /// Comments and strings, drawn over the text without making it rich,
        /// so a paste stays the characters you copied.
        func paint(_ view: NSTextView) {
            guard let layout = view.layoutManager, let storage = view.textStorage else { return }
            let whole = NSRange(location: 0, length: storage.length)
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
            let source = storage.string as NSString
            let comment = NSColor.tertiaryLabelColor
            let string = NSColor.secondaryLabelColor
            var index = 0
            while index < source.length {
                let character = source.character(at: index)
                if character == 47, index + 1 < source.length, source.character(at: index + 1) == 42 {
                    var end = index + 2
                    while end + 1 < source.length {
                        if source.character(at: end) == 42, source.character(at: end + 1) == 47 {
                            end += 2
                            break
                        }
                        end += 1
                    }
                    if end > source.length { end = source.length }
                    layout.addTemporaryAttribute(.foregroundColor, value: comment, forCharacterRange: NSRange(location: index, length: end - index))
                    index = end
                    continue
                }
                if kind == .javaScript, character == 47, index + 1 < source.length, source.character(at: index + 1) == 47 {
                    var end = index + 2
                    while end < source.length, source.character(at: end) != 10 { end += 1 }
                    layout.addTemporaryAttribute(.foregroundColor, value: comment, forCharacterRange: NSRange(location: index, length: end - index))
                    index = end
                    continue
                }
                if character == 34 || character == 39 {
                    var end = index + 1
                    while end < source.length {
                        let next = source.character(at: end)
                        if next == 92 { end += 2; continue }
                        end += 1
                        if next == character || next == 10 { break }
                    }
                    if end > source.length { end = source.length }
                    layout.addTemporaryAttribute(.foregroundColor, value: string, forCharacterRange: NSRange(location: index, length: end - index))
                    index = end
                    continue
                }
                index += 1
            }
        }
    }
}
