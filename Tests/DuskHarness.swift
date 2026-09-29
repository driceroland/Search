import AppKit
import Foundation
import WebKit

// Dark pages (Dusk.swift), on pages made to look every way a site can.
//
//     swiftc -parse-as-library Tests/DuskHarness.swift -o .build/dusk-harness && .build/dusk-harness [SHOTS_DIR]
//
// The page script is read out of Dusk.swift, with the colour engine from
// DuskColours.swift in its slot, so this runs what ships.
// Each fixture is loaded in a dark web view, as Search's are while its frame
// is dark, with the script put in before the document as Tab.arm puts it;
// then what the page measured and whether it was darkened are checked. With
// a folder named, a PNG of each page goes there, to look at by eye.

@MainActor
private final class DuskHarness: NSObject, NSApplicationDelegate, WKScriptMessageHandler {
    private struct Fixture {
        let name: String
        let html: String
        /// What the page should measure: true, dark by itself.
        let dark: Bool
        /// Whether it should end up darkened.
        let shown: Bool
        var sites: [String: Bool] = [:]
        var seen: [String: Bool] = [:]
        /// Which elements should be kept as the site made them, and which
        /// turned over with the page: selectors, each checked for the mark.
        var kept: [String] = []
        var turned: [String] = []
        /// "colours", or "filter" to keep the page to the filter.
        var mode = "colours"
        /// JavaScript that should be true of the darkened page, with
        /// lum(selector, property) and ok(selector, property) to read it.
        /// A selector reaches into a shadow root with " >>> ".
        var looks: [String] = []
        /// Each frame, by its document's title: whether it should end up
        /// darkened.
        var frames: [String: Bool] = [:]
        /// How long after the load to look.
        var settle: Double = 0.6
        /// Served from a scheme of its own (test-page://NAME/) rather than
        /// given as a string: a page that can load a sheet from another
        /// origin (test-other://), whose rules it then can't read.
        var served = false
    }

    private static let world = WKContentWorld.world(name: "Search")
    private var failures = 0
    private var told: [[String: Any]] = []
    /// As DuskRelay keeps them: the frames that asked, and whether the page
    /// is darkened now, which they are told.
    private var frameInfos: [WKFrameInfo] = []
    private var pageOn = false
    private weak var current: WKWebView?
    private let shots: URL? = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }

    private static let card = """
    <h2>A light page</h2>
    <div style="background:#f3f6fb;border:1px solid #d8dee9;padding:12px;border-radius:8px">Text with a <a href=#>link</a></div>
    <p><img width=80 height=40 src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='80' height='40'%3E%3Crect width='40' height='40' fill='%23e53935'/%3E%3Crect x='40' width='40' height='40' fill='%23fdd835'/%3E%3C/svg%3E"> a picture, which keeps its colours</p>
    """

    private let fixtures: [Fixture] = [
        Fixture(name: "light", html: "<style>body{background:#fff;color:#222;font:15px -apple-system}</style>" + card,
                dark: false, shown: true),
        Fixture(name: "follows-scheme", html: """
            <style>body{background:#fff;color:#222}@media (prefers-color-scheme: dark){body{background:#111;color:#eee}}</style>\(card)
            """, dark: true, shown: false),
        Fixture(name: "own-dark-theme", html: """
            <html class=dark><style>html.dark body{background:#0d1117;color:#c9d1d9}</style>\(card)</html>
            """, dark: true, shown: false),
        Fixture(name: "no-colours-at-all", html: "<p>Plain text, as a .txt or an old page has it.</p>",
                dark: false, shown: true),
        Fixture(name: "body-ground-only", html: "<style>body{background:#f7f7f7;margin:40px}</style>" + card,
                dark: false, shown: true),
        Fixture(name: "meta-color-scheme-dark", html: "<meta name=color-scheme content=\"dark\"><p>Dark by the browser's own colours.</p>",
                dark: true, shown: false),
        Fixture(name: "oklch-ground", html: "<style>body{background:oklch(0.98 0.01 250);color:oklch(0.2 0 0)}</style>" + card,
                dark: false, shown: true),
        // An app drawn after it loads: an empty shell first, then its own
        // dark ground. In the colours it stays as it drew itself, dark, and
        // isn't measured again for it (see Dusk.step); under the filter it is,
        // since the filter would turn it light.
        Fixture(name: "app-drawn-late", html: """
            <body><script>setTimeout(function(){var d=document.createElement('div');d.id='app';d.style.cssText='position:fixed;inset:0;background:#181818;color:#ddd';d.textContent='The app';document.body.appendChild(d)},250)</script></body>
            """, dark: false, shown: true,
                looks: ["lum('#app','backgroundColor') < 0.02", "lum('#app','color') > 0.6"], settle: 1.0),
        Fixture(name: "app-drawn-late-filtered", html: """
            <body><script>setTimeout(function(){var d=document.createElement('div');d.style.cssText='position:fixed;inset:0;background:#181818;color:#ddd';d.textContent='The app';document.body.appendChild(d)},250)</script></body>
            """, dark: true, shown: false, mode: "filter", settle: 1.0),
        // A site's own switch, flipped after it loads. Under the filter the
        // page is measured again and let go, since turned over its dark look
        // comes out light; in the colours it stays darkened and looks as the
        // site's dark look does (see Dusk.step).
        Fixture(name: "theme-switched-later", html: """
            <style>body{background:#fff}html.dark body{background:#111;color:#eee}</style>\(card)
            <script>setTimeout(function(){document.documentElement.className='dark'},300)</script>
            """, dark: true, shown: false, mode: "filter", settle: 1.0),
        Fixture(name: "theme-switched-later-colours", html: """
            <style>body{background:#fff}html.dark body{background:#111;color:#eee}</style>\(card)
            <script>setTimeout(function(){document.documentElement.className='dark'},300)</script>
            """, dark: false, shown: true,
                looks: ["lum('body','backgroundColor') < 0.02", "lum('body','color') > 0.6"], settle: 1.0),
        Fixture(name: "turned-off-for-site", html: "<style>body{background:#fff}</style>" + card,
                dark: false, shown: false, sites: ["turned-off-for-site.test": false]),
        Fixture(name: "turned-on-for-dark-site", html: "<style>body{background:#111;color:#eee}</style>" + card,
                dark: true, shown: true, sites: ["turned-on-for-dark-site.test": true]),
        // A light page with a dark bar, as Amazon's: the bar is kept, and
        // the white search box in it is kept with it.
        Fixture(name: "dark-bar-on-light-page", html: """
            <style>body{margin:0;background:#fff}#bar{background:#131921;color:#fff;padding:12px}#bar input{background:#fff}</style>
            <div id=bar>Logo <input id=box></div><p id=text>Light page text</p>
            """, dark: false, shown: true, kept: ["#bar", "#box"], turned: ["#text"], mode: "filter"),
        // A photo from a stylesheet is kept; an icon from a sprite isn't.
        Fixture(name: "css-photo-and-icon", html: """
            <style>body{background:#fff}#hero{width:300px;height:120px;background:url('data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22/%3E') center/cover}
            #icon{width:16px;height:16px;display:inline-block;background:url('data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22/%3E')}</style>
            <div id=hero></div><span id=icon></span>
            """, dark: false, shown: true, kept: ["#hero"], turned: ["#icon"], mode: "filter"),
        // A headline written over a picture that fills its card is kept with
        // the picture; a card with its title under the picture isn't.
        Fixture(name: "headline-over-picture", html: """
            <style>body{background:#fff}.card{position:relative;width:300px;height:160px}.card img{position:absolute;inset:0;width:100%;height:100%}.card h2{position:relative;color:#fff}
            .tile{width:300px}.tile img{width:300px;height:160px;display:block}</style>
            <div class=card id=card><img src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='300' height='160'%3E%3Crect width='300' height='160' fill='%232a6'/%3E%3C/svg%3E"><h2>Over the photo</h2></div>
            <div class=tile id=tile><img src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='300' height='160'%3E%3Crect width='300' height='160' fill='%23a62'/%3E%3C/svg%3E"><p>A title under it, and a price</p><p>$12.99</p><p>Free delivery</p></div>
            """, dark: false, shown: true, kept: ["#card"], turned: ["#tile"], mode: "filter", settle: 0.8),
        // Added after the page is up, as a carousel's next slide.
        Fixture(name: "dark-part-added-later", html: """
            <style>body{background:#fff}</style><p>Light</p>
            <script>setTimeout(function(){var d=document.createElement('footer');d.id='late';d.style.cssText='background:#232f3e;color:#fff;padding:20px';d.textContent='Footer';document.body.appendChild(d)},400)</script>
            """, dark: false, shown: true, kept: ["#late"], mode: "filter", settle: 1.0),
        // In the site's own colours (DuskColours.swift).
        Fixture(name: "colours-plain", html: "<style>body{background:#fff;color:#222}a{color:#0645ad}</style><p id=p>Text <a id=a href=#>link</a></p>",
                dark: false, shown: true,
                looks: ["lum('body','backgroundColor') < 0.05", "lum('#p','color') > 0.4",
                        "ok('#a','color')[1] > 0.1", "Math.abs(ok('#a','color')[2] - 264) < 10"]),
        Fixture(name: "colours-variables", html: """
            <style>:root{--ground:#fafafa;--ink:#111;--line:#ddd}body{background:var(--ground);color:var(--ink)}
            #card{border:1px solid var(--line);padding:8px}</style><div id=card>Card</div>
            """, dark: false, shown: true,
                looks: ["lum('body','backgroundColor') < 0.05", "lum('body','color') > 0.4",
                        "lum('#card','borderTopColor') < 0.12", "lum('#card','borderTopColor') > lum('body','backgroundColor')"]),
        // Hacker News, near enough: colours in attributes, not sheets.
        Fixture(name: "colours-attributes", html: """
            <table id=t bgcolor="#f6f6ef" width=100%><tr><td id=bar bgcolor="#ff6600">Hacker News</td></tr>
            <tr><td><font id=f color="#828282">points</font> <svg width=10 height=10><rect id=r width=10 height=10 fill="#000"/></svg></td></tr></table>
            """, dark: false, shown: true,
                looks: ["lum('#t','backgroundColor') < 0.05", "ok('#bar','backgroundColor')[1] > 0.1", "Math.abs(ok('#bar','backgroundColor')[2] - 43) < 8", "lum('#bar','backgroundColor') < 0.25",
                        "lum('#f','color') > 0.3", "lum('#r','fill') > 0.4"]),
        Fixture(name: "colours-style-attribute", html: """
            <style>body{background:#fff}</style><div id=d style="background-color:#fff;color:#000;border:2px solid #ccc">Inline</div>
            """, dark: false, shown: true,
                looks: ["lum('#d','backgroundColor') < 0.05", "lum('#d','color') > 0.4"]),
        // The cascade as the site had it: a later layer wins, a media query
        // only where it matches, a nested rule, a selector's specificity.
        Fixture(name: "colours-cascade", html: """
            <style>@layer base, theme; @layer theme { #l { background: #f00 } } @layer base { #l { background: #00f } }
            @media (min-width: 1px) { #m { background: #0a0 } } @media (max-width: 1px) { #m { background: #f0f } }
            #n { & span { color: #a00 } } .s { color: #00f } #s.s { color: #0a0 }</style>
            <div id=l>layer</div><div id=m>media</div><div id=n><span id=ns>nested</span></div><p id=s class=s>specific</p>
            """, dark: false, shown: true,
                looks: ["Math.abs(ok('#l','backgroundColor')[2] - 29) < 10", "Math.abs(ok('#m','backgroundColor')[2] - 142) < 10",
                        "Math.abs(ok('#ns','color')[2] - 29) < 10", "Math.abs(ok('#s','color')[2] - 142) < 10"]),
        // Rules that come after the page is up: a new <style>, and one added
        // by script to a sheet, which changes no markup.
        Fixture(name: "colours-late-rules", html: """
            <style id=first>body{background:#fff}</style><div id=a class=a>A</div><div id=b class=b>B</div>
            <script>setTimeout(function(){var s=document.createElement('style');s.textContent='.a{background:#fff}';document.head.appendChild(s);
            document.getElementById('first').sheet.insertRule('.b{background:#fff}',1)},300)</script>
            """, dark: false, shown: true,
                looks: ["lum('#a','backgroundColor') < 0.05", "lum('#b','backgroundColor') < 0.05"], settle: 1.8),
        // Already dark in places: kept dark, its writing kept light.
        Fixture(name: "colours-dark-bar", html: """
            <style>body{background:#fff}#bar{background:#131921;color:#fff}</style><div id=bar>Bar</div><p>Page</p>
            """, dark: false, shown: true,
                looks: ["lum('#bar','backgroundColor') < 0.02", "lum('#bar','color') > 0.7"]),
        Fixture(name: "colours-no-colours", html: "<p id=p>Nothing set at all</p>", dark: false, shown: true,
                looks: ["lum('#p','color') > 0.4"]),
        // Dark writing laid over a light photo stays dark; a title under
        // a picture is the page's, and goes light.
        Fixture(name: "colours-over-a-picture", html: """
            <style>body{background:#fff;color:#111}.card{position:relative;width:300px;height:160px}.card img{position:absolute;inset:0;width:100%;height:100%}
            .card h2{position:relative;color:#111}.tile img{width:300px;height:160px;display:block}</style>
            <div class=card><img src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='300' height='160'%3E%3Crect width='300' height='160' fill='%23eee'/%3E%3C/svg%3E"><h2 id=over>Over the photo</h2></div>
            <div class=tile><img src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='300' height='160'%3E%3Crect width='300' height='160' fill='%23a62'/%3E%3C/svg%3E"><p id=under>A title under it</p><p>$12.99</p><p>Free delivery</p></div>
            <a class=link style="display:block;width:300px"><img style="display:block;width:300px;height:160px" src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='300' height='160'%3E%3Crect width='300' height='160' fill='%23ccc'/%3E%3C/svg%3E"><span id=caption style="color:#111">Footwear</span></a>
            """, dark: false, shown: true,
                looks: ["lum('#over','color') < 0.02", "lum('#under','color') > 0.4", "lum('#caption','color') > 0.4"], settle: 0.8),
        // A field whose colour is animated by the site: measuring the page
        // must leave nothing running, and the field dark.
        Fixture(name: "colours-transitions", html: """
            <style>body{background:#fff}#f{border:none;transition:background-color .2s linear}#b{background:#fff;transition:background-color 1s}</style>
            <input id=f><button id=b>Button</button>
            """, dark: false, shown: true,
                looks: ["lum('#f','backgroundColor') < 0.05", "lum('#b','backgroundColor') < 0.05",
                        "document.getElementById('f').getAnimations().length === 0 && document.getElementById('b').getAnimations().length === 0"]),
        Fixture(name: "colours-gradients-masks-icons", html: """
            <style>body{background:#fff}#g{height:20px;background-image:linear-gradient(90deg,#fff,rgba(255,255,255,0))}
            #i{width:20px;height:20px;background-color:#202122;-webkit-mask-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg'/%3E")}</style>
            <div id=g></div><div id=i></div>
            <select id=sel style="width:200px;height:44px;appearance:none;background:#fff url('data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 width=%2216%22 height=%2216%22/%3E') no-repeat right 8px center"><option>All Categories</select>
            """, dark: false, shown: true,
                looks: ["!document.getElementById('sel').hasAttribute('data-office-dusk')", "lum('#sel','backgroundColor') < 0.05",
                        "getComputedStyle(document.getElementById('g')).backgroundImage.indexOf('oklch(0.2') >= 0",
                        "lum('#i','backgroundColor') > 0.4"]),
        // An icon whose mask and colour come from two rules, and a logo
        // drawn black on nothing, next to a photo that must be left alone.
        Fixture(name: "colours-icons-and-logos", html: """
            <style>body{background:#fff}.icon{display:inline-block;width:20px;height:20px;background-color:#202122}
            .icon-menu{-webkit-mask-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg'/%3E")}</style>
            <span id=menu class="icon icon-menu"></span>
            <img id=logo width=140 height=22 src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='140' height='22'%3E%3Crect x='10' y='4' width='60' height='14' fill='%23000'/%3E%3C/svg%3E">
            <img id=photo width=140 height=22 src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='140' height='22'%3E%3Crect width='140' height='22' fill='%23e53935'/%3E%3C/svg%3E">
            """, dark: false, shown: true,
                looks: ["lum('#menu','backgroundColor') > 0.4", "document.getElementById('logo').hasAttribute('data-office-dusk-icon')",
                        "!document.getElementById('photo').hasAttribute('data-office-dusk-icon')"], settle: 0.8),
        // A product photo blended into its light tile: onto a dark one the
        // blend would take it, and the badge on it, down to black.
        Fixture(name: "colours-blend-modes", html: """
            <style>body{background:#fff}.tile{background:#f7f7f7;padding:10px}.tile img{mix-blend-mode:multiply}.deal{mix-blend-mode:multiply;background:#fff}</style>
            <div class=tile><img id=pic width=100 height=60 src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg'/%3E"><div id=deal class=deal>50% off</div></div>
            """, dark: false, shown: true,
                looks: ["getComputedStyle(document.getElementById('pic')).mixBlendMode === 'normal'",
                        "getComputedStyle(document.getElementById('deal')).mixBlendMode === 'normal'"]),
        // Frames follow their page: a light one darkens with it, a dark one
        // (a video player) is left alone, and one from another origin too.
        Fixture(name: "frames-on-a-light-page", html: """
            <style>body{background:#fff;color:#111}iframe{width:200px;height:80px;border:0}</style><p>Page</p>
            <iframe srcdoc="<title>light-frame</title><style>body{background:#fff;color:#111}</style><p>Comments</p>"></iframe>
            <iframe srcdoc="<title>dark-frame</title><style>body{background:#111;color:#eee}</style><p>Player</p>"></iframe>
            <iframe src="data:text/html,<title>other-origin</title><style>body{background:%23fff}</style><p>Widget</p>"></iframe>
            """, dark: false, shown: true,
                frames: ["light-frame": true, "dark-frame": false, "other-origin": true], settle: 1.2),
        // A frame inside a frame, as W3Schools' "Try it" shows one: an
        // inline ground and a heading with no colour of its own.
        Fixture(name: "frames-nested", html: """
            <style>body{background:#fff}iframe{width:320px;height:200px;border:0}</style>
            <iframe srcdoc="<title>outer</title><body style='background:#fff'><h2>Outer</h2><iframe style='width:260px;height:120px' srcdoc='<title>inner</title><body style=&quot;background-color:lightblue&quot;><h1 id=h>In a frame</h1>'></iframe>"></iframe>
            """, dark: false, shown: true, frames: ["outer": true, "inner": true], settle: 1.5),
        // A page dark by itself isn't darkened, and neither are its frames.
        Fixture(name: "frames-on-a-dark-page", html: """
            <style>body{background:#fff}@media (prefers-color-scheme: dark){body{background:#111;color:#eee}}iframe{width:200px;height:80px}</style>
            <iframe srcdoc="<title>light-frame</title><style>body{background:#fff}</style><p>Widget</p>"></iframe>
            """, dark: true, shown: false, frames: ["light-frame": false], settle: 1.2),
        // Shadow roots: styled by a <style> inside, by an adopted sheet, and
        // one made after the page is up, which is only found by the sweep.
        Fixture(name: "shadow-roots", html: """
            <style>body{background:#fff}</style>
            <div id=a></div><div id=b></div><div id=c></div>
            <script>
            var a = document.getElementById('a').attachShadow({mode: 'open'});
            a.innerHTML = '<style>:host{display:block;background:#fff;color:#111}.in{background:#f5f5f5}</style><p class=in>Inside</p>';
            var b = document.getElementById('b').attachShadow({mode: 'open'}), sheet = new CSSStyleSheet();
            sheet.replaceSync('.in{background:#fff;color:#000}'); b.adoptedStyleSheets = [sheet]; b.innerHTML = '<p class=in>Adopted</p>';
            setTimeout(function () {
              var c = document.getElementById('c').attachShadow({mode: 'open'});
              c.innerHTML = '<style>.in{background:#fff}</style><p class=in>Late</p>';
            }, 400);
            </script>
            """, dark: false, shown: true,
                looks: ["lum('#a','backgroundColor') < 0.05", "lum('#a','color') > 0.4", "lum('#a >>> .in','backgroundColor') < 0.05",
                        "lum('#b >>> .in','backgroundColor') < 0.05", "lum('#b >>> .in','color') > 0.4",
                        "lum('#c >>> .in','backgroundColor') < 0.05"], settle: 2.0),
        // A sheet from another origin can't be read: what it colours is read
        // off the elements, and taken dark, with nothing asked for again.
        Fixture(name: "colours-unreadable-sheet", html: """
            <link rel=stylesheet href="test-other://cdn/sheet.css"><style>body{background:#fff}</style>
            <div id=a class=cdn>From a CDN <span id=inner>inside</span></div><div id=b class=cdn-card>Card</div>
            """, dark: false, shown: true,
                looks: ["lum('#a','backgroundColor') < 0.05", "lum('#a','color') > 0.4", "lum('#inner','color') > 0.4",
                        "lum('#a','borderTopColor') < 0.12", "lum('#b','backgroundColor') < 0.05",
                        "!document.getElementById('inner').hasAttribute('data-office-dusk-paint')",
                        "window.__officeDusk.state().colours.unreadable === true"], settle: 1.0, served: true),
        // The site's own rules are never touched: darkened or let go, each
        // says what the page read before anything was darkened.
        Fixture(name: "colours-leave-the-site-alone", html: """
            <style>body{background:#fff;color:#222;border-top:1px solid var(--line,#ddd)}@media (min-width:1px){p{color:#333}}</style>
            <script>var r = document.styleSheets[0].cssRules; document.documentElement.dataset.before = r[0].style.cssText + '|' + r[1].cssRules[0].style.cssText;</script>
            <p id=p>Text</p>
            """, dark: false, shown: true,
                looks: ["lum('body','backgroundColor') < 0.05", "lum('#p','color') > 0.3",
                        "(function () { var r = document.styleSheets[0].cssRules; return r[0].style.cssText + '|' + r[1].cssRules[0].style.cssText === document.documentElement.dataset.before; })()",
                        "(function () { window.__officeDusk.update({ on: false }); var r = document.styleSheets[0].cssRules; return r[0].style.cssText + '|' + r[1].cssRules[0].style.cssText === document.documentElement.dataset.before && lum('body','backgroundColor') > 0.9; })()"]),
        Fixture(name: "known-light-from-start", html: "<style>body{background:#fff}</style>" + card,
                dark: false, shown: true, seen: ["known-light-from-start.test": false]),
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        Task {
            let script = Self.script()
            for fixture in fixtures { await run(fixture, script) }
            print(failures == 0 ? "all \(fixtures.count) pages as expected" : "\(failures) failed")
            exit(failures == 0 ? 0 : 1)
        }
    }

    /// The page script with the colour engine in its slot, as Dusk.whole has it.
    private static func script() -> String {
        let page = constant("static let script", in: "Dusk.swift")
        return page.replacingOccurrences(of: "/*COLOURS*/", with: constant("static let engine", in: "DuskColours.swift"))
    }

    private static func constant(_ name: String, in file: String) -> String {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = (try? String(contentsOf: here.appendingPathComponent("../Sources/Search/" + file), encoding: .utf8)) ?? ""
        guard let start = source.range(of: name + " = #\"\"\"\n"),
              let end = source.range(of: "\"\"\"#", range: start.upperBound..<source.endIndex) else {
            print("FAIL no \(name) in \(file)"); exit(1)
        }
        return String(source[start.upperBound..<end.lowerBound])
    }

    /// For a fixture's looks: an element's colour as luminance, and as oklch.
    private static let helpers = """
    var pen = document.createElement('canvas').getContext('2d', { willReadFrequently: true });
    var lin = function (c) { c /= 255; return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); };
    var find = function (sel) {
      var parts = sel.split(' >>> '), at = document;
      for (var i = 0; i < parts.length; i++) { var el = at.querySelector(parts[i]); at = i < parts.length - 1 ? el.shadowRoot : el; }
      return at;
    };
    var lum = function (sel, prop) {
      pen.clearRect(0, 0, 1, 1); pen.fillStyle = 'rgba(0,0,0,0)'; pen.fillStyle = getComputedStyle(find(sel))[prop];
      pen.fillRect(0, 0, 1, 1); var d = pen.getImageData(0, 0, 1, 1).data;
      return 0.2126 * lin(d[0]) + 0.7152 * lin(d[1]) + 0.0722 * lin(d[2]);
    };
    var ok = function (sel, prop) {
      var m = /oklch\\(([\\d.]+) ([\\d.]+) ([\\d.]+)/.exec(getComputedStyle(find(sel))[prop]);
      return m ? [+m[1], +m[2], +m[3]] : [NaN, NaN, NaN];
    };
    """

    private func run(_ fixture: Fixture, _ script: String) async {
        told = []
        frameInfos = []
        pageOn = false
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // A stylesheet from another origin, as a CDN's is: its rules can't be
        // read from the page, and it is never asked for again.
        let schemes = OtherOrigin()
        configuration.setURLSchemeHandler(schemes, forURLScheme: "test-other")
        configuration.setURLSchemeHandler(schemes, forURLScheme: "test-page")
        // Only this one site's answers, as Dusk.config hands them over.
        let host = "\(fixture.name).test"
        let config: [String: Any] = ["on": true, "host": host, "mode": fixture.mode,
                                     "choice": fixture.sites[host].map { $0 as Any } ?? NSNull(),
                                     "known": fixture.seen[host].map { $0 as Any } ?? NSNull()]
        let json = String(data: (try? JSONSerialization.data(withJSONObject: config)) ?? Data(), encoding: .utf8) ?? "{}"
        let controller = configuration.userContentController
        controller.add(self, contentWorld: Self.world, name: "officeDusk")
        controller.addUserScript(WKUserScript(source: "(\(script))(\(json));", injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: Self.world))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 320), configuration: configuration)
        // Off every screen, a window counts as covered, and WebKit gives a page
        // nobody sees no frames: the measuring waits for one. Told to paint
        // regardless, as the bench's stand is.
        let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if web.responds(to: occlusion) {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(web.method(for: occlusion), to: Setter.self)(web, occlusion, false)
        }
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 520, height: 320),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = web
        window.orderFrontRegardless()
        current = web
        if fixture.served, let page = URL(string: "test-page://\(fixture.name)/") {
            OtherOrigin.page = fixture.html
            web.load(URLRequest(url: page))
        } else {
            web.loadHTMLString(fixture.html, baseURL: URL(string: "https://\(fixture.name).test/"))
        }

        try? await Task.sleep(for: .seconds(0.4 + fixture.settle))
        let state = try? await web.evaluateJavaScript("window.__officeDusk.state()", in: nil, contentWorld: Self.world) as? [String: Any]
        let native = state?["native"] as? Bool
        let shown = state?["shown"] as? Bool ?? false
        let marks = (fixture.kept.map { ($0, true) } + fixture.turned.map { ($0, false) })
        var wrong: [String] = []
        for (selector, want) in marks {
            let has = try? await web.evaluateJavaScript("!!document.querySelector('\(selector)').closest('[data-office-dusk]')",
                                                        in: nil, contentWorld: Self.world) as? Bool
            if has != want { wrong.append("\(selector) \(want ? "not kept" : "kept")") }
        }
        for look in fixture.looks {
            let held = try? await web.evaluateJavaScript("(function(){ \(Self.helpers) try { return !!(\(look)); } catch (e) { return false; } })()",
                                                         in: nil, contentWorld: Self.world) as? Bool
            if held != true { wrong.append(look) }
        }
        for (title, want) in fixture.frames {
            var found: Bool?
            for frame in frameInfos {
                let said = try? await web.evaluateJavaScript("[document.title, window.__officeDusk ? window.__officeDusk.state().shown : null]",
                                                             in: frame, contentWorld: Self.world) as? [Any]
                if said?.first as? String == title { found = said?.last as? Bool; break }
            }
            if found != want { wrong.append("frame \(title): \(found.map { $0 ? "darkened" : "left alone" } ?? "never asked")") }
        }
        // Darkened the way it was asked to be: in its colours where the
        // browser can, by the filter where it was kept to it.
        let mode = state?["mode"] as? String ?? "none"
        if fixture.shown, mode != fixture.mode { wrong.append("darkened by \(mode), not \(fixture.mode)") }
        let ok = native == fixture.dark && shown == fixture.shown && wrong.isEmpty
        if !ok { failures += 1 }
        if !wrong.isEmpty { print("     \(wrong.joined(separator: ", "))") }
        let heard = told.map { "\($0["on"] as? Bool == true ? "on" : "off")" }.joined(separator: ",")
        let took = (state?["colours"] as? [String: Any]).map { " \($0["twins"] ?? 0) twins, \($0["ms"] ?? 0) ms" } ?? ""
        print("\(ok ? "ok  " : "FAIL") \(fixture.name): measured \(native.map { $0 ? "dark" : "light" } ?? "nothing"), "
              + "\(shown ? "darkened by \(mode)" : "left alone") (told: \(heard))\(took)")

        if let shots {
            try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
            if let image = try? await web.takeSnapshot(configuration: nil),
               let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: shots.appendingPathComponent("\(fixture.name).png"))
            }
        }
        controller.removeScriptMessageHandler(forName: "officeDusk", contentWorld: Self.world)
        window.orderOut(nil)
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let frame = message.frameInfo
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any], let web = current else { return }
            // What DuskRelay does: a frame is kept and told whether its page
            // is darkened; the page's changes are told to every frame.
            if !frame.isMainFrame {
                guard body["frame"] as? Bool == true else { return }
                frameInfos.append(frame)
                web.evaluateJavaScript("window.__officeDusk && window.__officeDusk.top(\(pageOn))", in: frame, in: Self.world) { _ in }
                return
            }
            told.append(body)
            let on = body["on"] as? Bool ?? false
            guard on != pageOn else { return }
            pageOn = on
            for f in frameInfos {
                web.evaluateJavaScript("window.__officeDusk && window.__officeDusk.top(\(on))", in: f, in: Self.world) { _ in }
            }
        }
    }
}

/// Serves a served fixture's page (test-page://) and a stylesheet from
/// another origin (test-other://), as a CDN's is to the page.
private final class OtherOrigin: NSObject, WKURLSchemeHandler {
    static let css = ".cdn{background:#fff;color:#111;border:2px solid #ddd}.cdn-card{background:#f4f4f4}"
    static var page = ""
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let css = url.scheme == "test-other"
        let data = Data((css ? OtherOrigin.css : OtherOrigin.page).utf8)
        task.didReceive(URLResponse(url: url, mimeType: css ? "text/css" : "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

@main
@MainActor
private struct DuskHarnessApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let harness = DuskHarness()
        app.delegate = harness
        app.run()
        _ = harness
    }
}
