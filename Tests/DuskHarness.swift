import AppKit
import Foundation
import WebKit

// Dark pages (Dusk.swift), on pages made to look every way a site can.
//
//     swiftc -parse-as-library Tests/DuskHarness.swift -o .build/dusk-harness && .build/dusk-harness [SHOTS_DIR]
//
// The page script is read out of Dusk.swift itself, so this runs what ships.
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
        /// How long after the load to look.
        var settle: Double = 0.6
    }

    private static let world = WKContentWorld.world(name: "Search")
    private var failures = 0
    private var told: [[String: Any]] = []
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
        // An app drawn after it loads: an empty shell first, then its own dark ground.
        Fixture(name: "app-drawn-late", html: """
            <body><script>setTimeout(function(){var d=document.createElement('div');d.style.cssText='position:fixed;inset:0;background:#181818;color:#ddd';d.textContent='The app';document.body.appendChild(d)},250)</script></body>
            """, dark: true, shown: false, settle: 1.0),
        // A site's own switch, flipped after it loads.
        Fixture(name: "theme-switched-later", html: """
            <style>body{background:#fff}html.dark body{background:#111;color:#eee}</style>\(card)
            <script>setTimeout(function(){document.documentElement.className='dark'},300)</script>
            """, dark: true, shown: false, settle: 1.0),
        Fixture(name: "turned-off-for-site", html: "<style>body{background:#fff}</style>" + card,
                dark: false, shown: false, sites: ["turned-off-for-site.test": false]),
        Fixture(name: "turned-on-for-dark-site", html: "<style>body{background:#111;color:#eee}</style>" + card,
                dark: true, shown: true, sites: ["turned-on-for-dark-site.test": true]),
        // A light page with a dark bar, as Amazon's: the bar is kept, and
        // the white search box in it is kept with it.
        Fixture(name: "dark-bar-on-light-page", html: """
            <style>body{margin:0;background:#fff}#bar{background:#131921;color:#fff;padding:12px}#bar input{background:#fff}</style>
            <div id=bar>Logo <input id=box></div><p id=text>Light page text</p>
            """, dark: false, shown: true, kept: ["#bar", "#box"], turned: ["#text"]),
        // A photo from a stylesheet is kept; an icon from a sprite isn't.
        Fixture(name: "css-photo-and-icon", html: """
            <style>body{background:#fff}#hero{width:300px;height:120px;background:url('data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22/%3E') center/cover}
            #icon{width:16px;height:16px;display:inline-block;background:url('data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22/%3E')}</style>
            <div id=hero></div><span id=icon></span>
            """, dark: false, shown: true, kept: ["#hero"], turned: ["#icon"]),
        // A headline written over a picture that fills its card is kept with
        // the picture; a card with its title under the picture isn't.
        Fixture(name: "headline-over-picture", html: """
            <style>body{background:#fff}.card{position:relative;width:300px;height:160px}.card img{position:absolute;inset:0;width:100%;height:100%}.card h2{position:relative;color:#fff}
            .tile{width:300px}.tile img{width:300px;height:160px;display:block}</style>
            <div class=card id=card><img src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='300' height='160'%3E%3Crect width='300' height='160' fill='%232a6'/%3E%3C/svg%3E"><h2>Over the photo</h2></div>
            <div class=tile id=tile><img src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='300' height='160'%3E%3Crect width='300' height='160' fill='%23a62'/%3E%3C/svg%3E"><p>A title under it, and a price</p><p>$12.99</p><p>Free delivery</p></div>
            """, dark: false, shown: true, kept: ["#card"], turned: ["#tile"], settle: 0.8),
        // Added after the page is up, as a carousel's next slide.
        Fixture(name: "dark-part-added-later", html: """
            <style>body{background:#fff}</style><p>Light</p>
            <script>setTimeout(function(){var d=document.createElement('footer');d.id='late';d.style.cssText='background:#232f3e;color:#fff;padding:20px';d.textContent='Footer';document.body.appendChild(d)},400)</script>
            """, dark: false, shown: true, kept: ["#late"], settle: 1.0),
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

    private static func script() -> String {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = (try? String(contentsOf: here.appendingPathComponent("../Sources/Search/Dusk.swift"), encoding: .utf8)) ?? ""
        guard let start = source.range(of: "static let script = #\"\"\"\n"),
              let end = source.range(of: "\"\"\"#", range: start.upperBound..<source.endIndex) else {
            print("FAIL no script in Dusk.swift"); exit(1)
        }
        return String(source[start.upperBound..<end.lowerBound])
    }

    private func run(_ fixture: Fixture, _ script: String) async {
        told = []
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let config: [String: Any] = ["on": true, "sites": fixture.sites, "seen": fixture.seen]
        let json = String(data: (try? JSONSerialization.data(withJSONObject: config)) ?? Data(), encoding: .utf8) ?? "{}"
        let controller = configuration.userContentController
        controller.add(self, contentWorld: Self.world, name: "officeDusk")
        controller.addUserScript(WKUserScript(source: "(\(script))(\(json));", injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: Self.world))
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
        web.loadHTMLString(fixture.html, baseURL: URL(string: "https://\(fixture.name).test/"))

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
        let ok = native == fixture.dark && shown == fixture.shown && wrong.isEmpty
        if !ok { failures += 1 }
        if !wrong.isEmpty { print("     \(wrong.joined(separator: ", "))") }
        let heard = told.map { "\($0["on"] as? Bool == true ? "on" : "off")" }.joined(separator: ",")
        print("\(ok ? "ok  " : "FAIL") \(fixture.name): measured \(native.map { $0 ? "dark" : "light" } ?? "nothing"), "
              + "\(shown ? "darkened" : "left alone") (told: \(heard))")

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
        MainActor.assumeIsolated {
            if let body = message.body as? [String: Any] { told.append(body) }
        }
    }
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
