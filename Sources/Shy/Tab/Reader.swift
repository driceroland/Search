import SwiftUI

// Reading mode: the article, and nothing that was arranged around it.
//
// The hard part is deciding what the article is. The heuristic here is the old
// one and it holds up: the piece of the page carrying the most prose, punished
// for every link inside it — because navigation, related-articles rails and
// comment threads are all made of links, and prose is not.

enum Reader {
    /// The one look both kinds of reading share.
    private static let dark = "color-scheme:dark;--r-ground:#1c1c1c;--r-ink:#e0e0e0;--r-quiet:#8a8a8a;"
        + "--r-aside:#a8a8a8;--r-rule:#333;--r-code:#2a2a2a;--r-picture:brightness(.92)"

    static let sheet = [
        // Light, or dark as the window is or as chosen in the corner
        // (ReaderLook puts it on <html>, which the reader keeps). The dark
        // ground is the window's own (Palette.ground); the text a shade
        // softer than Palette.ink, there being a lot of it.
        ":root{color-scheme:light;--r-ground:#fff;--r-ink:#171717;--r-quiet:#a3a3a3;",
        "--r-aside:#555;--r-rule:#e8e8e8;--r-code:#f5f5f5;--r-picture:none}",
        "@media (prefers-color-scheme:dark){:root:not([data-office-look=light]){" + dark + "}}",
        ":root[data-office-look=dark]{" + dark + "}",
        "html,body{background:var(--r-ground) !important;margin:0 !important;padding:0 !important}",
        "#office-reader{max-width:38em;margin:0 auto;padding:72px 24px 160px;",
        "font:400 18px/1.72 ui-serif,Georgia,\"Times New Roman\",serif;color:var(--r-ink)}",
        "#office-reader h1{font:600 30px/1.24 -apple-system,BlinkMacSystemFont,sans-serif;",
        "margin:0 0 8px;letter-spacing:-0.01em}",
        "#office-reader .office-from{font:400 12px/1 -apple-system,sans-serif;color:var(--r-quiet);",
        "margin:0 0 40px;text-transform:uppercase;letter-spacing:.06em}",
        "#office-reader p{margin:0 0 1.35em}",
        "#office-reader img,#office-reader video,#office-reader iframe{max-width:100%;",
        "height:auto;border-radius:6px;margin:1.6em 0;display:block}",
        // A photo, a touch dimmer on dark, so it doesn't glare.
        "#office-reader img{filter:var(--r-picture)}",
        "#office-reader iframe{width:100%;aspect-ratio:16/9;height:auto;border:0}",
        "#office-reader svg{max-width:100%}",
        "#office-reader iframe.office-chart{aspect-ratio:auto}",
        "#office-reader figure{margin:1.8em 0}",
        "#office-reader figcaption{font:400 13px/1.5 -apple-system,sans-serif;",
        "color:var(--r-quiet);margin-top:.6em}",
        // A caption and its credit, which the site's own layout kept apart.
        "#office-reader figcaption > * + *{margin-left:.35em}",
        // The byline and a summary, quieter than the text.
        "#office-reader .office-above{font:400 14px/1.55 -apple-system,sans-serif;",
        "color:var(--r-aside);margin:0 0 1.6em}",
        "#office-reader .office-above ul{padding-left:1.2em}",
        "#office-reader .office-above h2{margin:.4em 0}",
        "#office-reader a{color:var(--r-ink);text-underline-offset:3px}",
        "#office-reader h2,#office-reader h3{font:600 20px/1.3 -apple-system,sans-serif;",
        "margin:2em 0 .6em}",
        "#office-reader h4,#office-reader h5,#office-reader h6{font:600 16px/1.4 -apple-system,sans-serif;",
        "margin:1.8em 0 .5em}",
        "#office-reader pre,#office-reader code,#office-reader kbd{font-family:ui-monospace,monospace;font-size:14px}",
        "#office-reader pre{background:var(--r-code);padding:14px;border-radius:8px;overflow:auto}",
        "#office-reader blockquote{margin:1.6em 0;padding-left:1.2em;",
        "border-left:2px solid var(--r-rule);color:var(--r-aside)}",
        // Said outright: a site's own reset (Tailwind's, most often) takes
        // the numbers off every list on the page, this one included.
        "#office-reader ul,#office-reader ol{margin:0 0 1.35em;padding-left:1.4em}",
        "#office-reader ul{list-style:disc outside}",
        "#office-reader ol{list-style:decimal outside}",
        "#office-reader li>ul{list-style-type:circle}",
        "#office-reader :not(pre)>code{background:var(--r-code);padding:.1em .35em;border-radius:4px}",
        "#office-reader li{margin:.3em 0}",
        "#office-reader li>ul,#office-reader li>ol{margin-bottom:0}",
        "#office-reader hr{border:0;border-top:1px solid var(--r-rule);margin:2.4em 0}",
        "#office-reader .office-wide{overflow-x:auto;margin:1.6em 0}",
        "#office-reader table{border-collapse:collapse;font:400 15px/1.5 -apple-system,sans-serif}",
        "#office-reader th,#office-reader td{border-bottom:1px solid var(--r-rule);padding:8px 12px 8px 0;",
        "text-align:left;vertical-align:top}",
        "#office-reader th{font-weight:600}",
        "#office-reader .office-part{font:600 16px/1.4 -apple-system,sans-serif;margin:1.8em 0 .5em}",
        "#office-reader details{margin:0 0 1.35em}",
        "#office-reader summary{cursor:pointer}",
    ].joined()

    /// Puts the reading page in place of the page: the title, where it's
    /// from, and what to read. Called with the sheet, since a script only
    /// knows what it's handed.
    ///
    /// The page's own stylesheets go first. Left in, they reach the reading
    /// page through every rule written for a bare element (Tailwind's reset
    /// took the numbers off every list) and every font the page loaded.
    /// Shy's own stay: each has an `office-` id, and Find on Page
    /// keeps its own in adoptedStyleSheets, which are left as they are. Done
    /// once, as reading mode opens; a page that adds a sheet back later keeps
    /// it, because a watcher that took it away again would fight any
    /// extension (Dark Reader, Stylus) that puts its own back, forever.
    static let present = Scripts.load("reader-present")

    /// The guess. Called with `sheet`.
    static let script = present + Scripts.load("reader")

    /// Light, dark, or as the window is: chosen on an article, and kept for
    /// the next one. Light whenever reading mode doesn't follow the window.
    static var look: Look {
        get {
            guard Store.settings.bool(forKey: "reader.follows") else { return .light }
            return Store.settings.string(forKey: "reader.look").flatMap(Look.init) ?? .system
        }
        set { Store.settings.set(newValue.rawValue, forKey: "reader.look") }
    }

    /// Puts a look on the page. It is on <html>, which the reader keeps, so
    /// it holds for the article and goes when the page does.
    static func apply(_ look: Look) -> String {
        look == .system
            ? "document.documentElement.removeAttribute('data-office-look');"
            : "document.documentElement.setAttribute('data-office-look','\(look.rawValue)');"
    }
}

/// The article's own light and dark, in its corner while it is up, with
/// reading mode following the window (Settings › General). Quiet until the
/// pointer comes to it.
struct ReaderLook: View {
    let tab: Tab
    @State private var look = Reader.look
    @State private var hovering = false
    @Environment(\.colorScheme) private var window

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Look.allCases) { each in
                Button {
                    look = each
                    Reader.look = each
                    tab.built?.evaluateJavaScript(Reader.apply(each))
                } label: {
                    Image(systemName: each == .light ? "sun.max" : each == .dark ? "moon" : "circle.lefthalf.filled")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(look == each ? Palette.ink : Palette.muted)
                        .frame(width: 24, height: 22)
                        .background(Capsule().fill(look == each ? Palette.wash : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(each == .system ? "As the window is" : each.title)
            }
        }
        .padding(3)
        .background(Palette.ground, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        // In the article's colours, which may not be the window's.
        .environment(\.colorScheme, look == .dark ? .dark : look == .light ? .light : window)
        .opacity(hovering ? 1 : 0.55)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: look)
        .padding(14)
        // An article read in another tab may have been given another look
        // since: the one kept is the one it wears when it comes back.
        .onAppear { tab.built?.evaluateJavaScript(Reader.apply(look)) }
    }
}
