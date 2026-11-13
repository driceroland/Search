import Foundation
import SwiftUI
import WebKit

// CSS you write for a site, and nothing else.
//
// Off until you turn it on in Settings › Browsing. Then View › Style This
// Site… edits the site you're on. It goes in before the page draws, the way
// something you've hidden does (see Curtain), and it is kept on this Mac in
// styles.json. Closing the panel keeps it; there is no account and nothing
// is sent anywhere.
//
// What you wrote is put in as text, so it can't close the style element and
// run as script. An imported sheet, or a web address in url(), is left out:
// either one would fetch from somewhere else, and Search doesn't fetch on a
// page's behalf except the page you asked for.

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

    @Published private(set) var byHost: [String: String] = [:]
    private var saving = false

    private init() { load() }

    func css(on host: String?) -> String? {
        guard let host else { return nil }
        return byHost[host]
    }

    /// Kept, after anything that would fetch has been taken out. Empty
    /// forgets the site.
    @discardableResult
    func save(_ raw: String, on host: String) -> Cleaned {
        let cleaned = Self.clean(raw)
        if cleaned.css.isEmpty {
            byHost[host] = nil
        } else {
            byHost[host] = cleaned.css
        }
        save()
        return cleaned
    }

    func remove(on host: String) {
        guard byHost[host] != nil else { return }
        byHost[host] = nil
        save()
    }

    /// The pages open now, so a change shows without a reload. Asleep ones
    /// are left alone: waking one would load it, and the next load arms it.
    func applyOpen() {
        let tabs = Browsers.all.flatMap { $0.tabs + [$0.peekTab].compactMap { $0 } } + LittleWindow.all.map(\.tab)
        for tab in tabs {
            guard let web = tab.built, let host = Dusk.host(of: tab.address) else { continue }
            let sheet = Self.on ? (css(on: host) ?? "") : ""
            web.evaluateJavaScript(Veiling.style(sheet, id: Self.element), in: nil, in: Web.world) { _ in }
        }
    }

    struct Cleaned: Equatable {
        var css: String
        /// Cut down to `limit`.
        var shortened = false
        /// An imported sheet or a web address in url() was left out.
        var fetched = false
    }

    /// What is safe to keep. Relative urls stay: they are the site's own.
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

    // MARK: - the file

    private static var file: URL { Store.file("styles.json") }

    private func load() {
        guard let data = try? Data(contentsOf: Self.file),
              let stored = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        byHost = stored
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

// MARK: - the panel

/// The CSS for the site on screen. Nothing here is fetched, and nothing is
/// kept until Save. A reload leaves it open, words and all. Another website
/// shows that site's sheet. A moment with no address is still this site.
struct StylePanel: View {
    @ObservedObject var browser: Browser
    @State private var text = ""
    /// The site the words on screen belong to.
    @State private var shown: String?

    var body: some View {
        Plate(browser.styleHost ?? shown ?? "This page", width: 420, close: { browser.styling = false }) {
            VStack(alignment: .leading, spacing: 8) {
                Caption("CSS for this site, applied before the page draws. A web address or an imported sheet is left out, so nothing is fetched.")
                TextEditor(text: $text)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 180, maxHeight: 280)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        } foot: {
            HStack(spacing: 8) {
                Pill("Remove") { remove() }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              && SiteStyles.shared.css(on: browser.styleHost) == nil)
                Spacer()
                Pill("Save", filled: true) { save() }
            }
        }
        .onAppear { show(browser.styleHost) }
        .onChange(of: browser.styleHost) { _, host in show(host) }
    }

    /// A reload keeps this sheet. No address for a moment is still this
    /// site, so the words stay. Only a different website loads its own.
    private func show(_ host: String?) {
        guard let host, host != shown else { return }
        shown = host
        text = SiteStyles.shared.css(on: host) ?? ""
    }

    private func save() {
        guard let host = browser.styleHost else { return }
        let cleaned = SiteStyles.shared.save(text, on: host)
        text = cleaned.css
        SiteStyles.shared.applyOpen()
        if cleaned.css.isEmpty {
            browser.announce(cleaned.fetched || cleaned.shortened
                             ? "Nothing kept — a web address or an imported sheet was left out"
                             : "Style removed")
        } else if cleaned.fetched {
            browser.announce("Style kept for \(host) — a web address or an imported sheet was left out")
        } else if cleaned.shortened {
            browser.announce("Style kept for \(host) — shortened")
        } else {
            browser.announce("Style kept for \(host)")
        }
    }

    private func remove() {
        guard let host = browser.styleHost else { return }
        SiteStyles.shared.remove(on: host)
        text = ""
        SiteStyles.shared.applyOpen()
        browser.announce("Style removed")
    }
}
