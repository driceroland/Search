import SwiftUI
import WebKit

// Developer Mode: a bar along the bottom of the page, for whoever is building
// the page rather than reading it. It holds the address of the page on screen
// in full — path, query and fragment, where the tab itself says only the site
// (see AtRest.swift) — as this tab's own address field; what the page answered
// and how long it took; how many of its scripts' errors there have been; and
// four buttons: a reload that skips the cache, the page's source, and the Web
// Inspector (see Inspector.swift). On by itself for a page from this Mac's own
// servers, and turned on or off for one tab from its right-click menu; that
// choice lasts as long as the tab is open.

/// What the bar knows of each page beyond its address, told by a script in
/// Shy's own world (see Web.world): the page cannot see it, and it carries
/// nothing back but three numbers. Only in a tab with Developer Mode on.
@MainActor
final class DevTools: NSObject, ObservableObject, WKScriptMessageHandler {
    static let shared = DevTools()
    static let name = "developer"

    struct Report: Equatable {
        /// The HTTP status of the page; none for a file, or a page from the
        /// back-forward cache.
        var status: Int?
        /// From the start of the navigation to the end of the page's load.
        var milliseconds: Int?
        /// Uncaught errors, unhandled rejections and `console.error`. The
        /// page can add to this as it likes; it is its own count.
        var errors = 0
    }

    /// By page view; a new document starts its own.
    @Published private(set) var reports: [ObjectIdentifier: Report] = [:]
    /// What is being typed in each window's bar, while it is; by window.
    @Published var drafts: [ObjectIdentifier: String] = [:]
    /// The tabs it was turned on or off for by hand.
    @Published private var chosen: [UUID: Bool] = [:]

    /// On for this tab: as it was turned by hand, or else for a page from
    /// this Mac — localhost, 127.x, ::1 — which is where pages are built.
    /// `url`: where the tab is going, when that is what is being decided.
    func isOn(_ tab: Tab, at url: URL? = nil) -> Bool {
        if let on = chosen[tab.id] { return on }
        guard let host = (url ?? tab.pageAddress)?.host() else { return false }
        return Hosts.isLoopback(Hosts.ascii(host))
    }

    /// The tab's right-click menu. Turned on, the page up is counted from now.
    func set(_ tab: Tab, on: Bool) {
        chosen[tab.id] = on
        if on { DevTools.attach(tab) }
    }

    /// Each view's last answer from a server, kept until its document
    /// starts: a load still on its way says nothing over the page on screen.
    private var answers: [ObjectIdentifier: Int] = [:]

    func answered(_ status: Int, in web: WKWebView, for tab: Tab, at url: URL?) {
        guard isOn(tab, at: url) else { return }
        answers[ObjectIdentifier(web)] = status
    }

    func report(for tab: Tab) -> Report? {
        tab.built.flatMap { reports[ObjectIdentifier($0)] }
    }

    // Shy's world, the main frame, before the page's own scripts: an error
    // in the page reaches every world's listeners, a console.error only the
    // page's (see `page`), which passes it on as an event.
    static let script = """
    (() => {
        if (window.__shyDeveloper) return;
        window.__shyDeveloper = true;
        const say = message => webkit.messageHandlers.developer.postMessage(message);
        let errors = 0;
        const count = () => say({ errors: ++errors });
        say({ start: true });
        addEventListener('error', event => { if (event instanceof ErrorEvent) count(); });
        addEventListener('unhandledrejection', count);
        addEventListener('shy-console-error', count);
        const timing = () => {
            const entry = performance.getEntriesByType('navigation')[0];
            if (!entry) return;
            say({ milliseconds: Math.round(entry.loadEventEnd - entry.startTime) });
        };
        if (document.readyState === 'complete') setTimeout(timing);
        else addEventListener('load', () => setTimeout(timing), { once: true });
    })();
    """

    // The page's own world, where its console is: console.error goes on as
    // it was, and says so with an event that carries nothing.
    static let page = """
    (() => {
        const error = console.error;
        if (error.__shyCounted) return;
        const counted = function () {
            dispatchEvent(new Event('shy-console-error'));
            return error.apply(this, arguments);
        };
        counted.__shyCounted = true;
        console.error = counted;
    })();
    //# sourceURL=shy-developer-mode.js
    """

    /// Each document's scripts, from Tab.arm: the next document gets them
    /// only with Developer Mode on for the tab, where it is going.
    static func arm(_ controller: WKUserContentController, for tab: Tab, to url: URL?) {
        controller.removeScriptMessageHandler(forName: name, contentWorld: Web.world)
        guard shared.isOn(tab, at: url) else { return }
        controller.add(shared, contentWorld: Web.world, name: name)
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Web.world))
        controller.addUserScript(WKUserScript(source: page, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
    }

    /// The page already up when the bar comes to it, which was armed
    /// before Developer Mode was on: counted from now.
    static func attach(_ tab: Tab) {
        guard shared.isOn(tab), let web = tab.built else { return }
        let controller = web.configuration.userContentController
        controller.removeScriptMessageHandler(forName: name, contentWorld: Web.world)
        controller.add(shared, contentWorld: Web.world, name: name)
        web.evaluateJavaScript(page, in: nil, in: .page) { _ in }
        web.evaluateInShy(script)
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated {
            guard let web = message.webView else { return }
            let id = ObjectIdentifier(web)
            var report = reports[id] ?? Report()
            if body["start"] != nil { report = Report(status: answers.removeValue(forKey: id)) }
            if let errors = body["errors"] as? Int { report.errors = max(0, errors) }
            if let milliseconds = body["milliseconds"] as? Int { report.milliseconds = max(0, milliseconds) }
            if reports[id] != report { reports[id] = report }
        }
    }

    /// What the field sends: an address, as the window's own field reads
    /// one — a file on this Mac, or a place — and never a search; nor
    /// `javascript:`, nor a scheme the window doesn't show. False with
    /// nothing loaded.
    static func go(_ typed: String, in tab: Tab) -> Bool {
        guard let url = Address.file(from: typed) ?? Address.url(from: typed) else { return false }
        tab.go(to: url)
        return true
    }

    /// Shy's world asks the page's own address again, as the page would,
    /// from the cache where it can: what the server sent, not what scripts
    /// have made of it since.
    private static let source = """
    const response = await fetch(location.href, { cache: 'force-cache', credentials: 'include' });
    return await response.text();
    """

    /// The page's source in a tab of its own, as plain text: a data address
    /// of type text/plain, which WebKit shows and never runs, as it shows a
    /// text file (see LocalText.swift).
    static func viewSource(of tab: Tab, in browser: Browser) {
        guard tab.isWeb, let web = tab.built else { return }
        Task { @MainActor in
            let text = try? await web.callAsyncJavaScript(source, arguments: [:], in: nil, contentWorld: Web.world) as? String
            guard let data = text?.data(using: .utf8), data.count <= LocalText.largest,
                  let url = URL(string: "data:text/plain;charset=utf-8;base64," + data.base64EncodedString())
            else {
                browser.announce("The page's source couldn't be read")
                return
            }
            _ = browser.open(url, foreground: true, from: tab)
        }
    }
}

/// The bar, for the tab in front while it has Developer Mode on. It watches
/// that tab, so a page moving on redraws the address; the window hands down a
/// new tab when you switch.
struct DeveloperBar: View {
    @ObservedObject var browser: Browser
    /// The card's gap above it, with the page as a card.
    var gap: CGFloat = 0

    var body: some View {
        if let tab = browser.active {
            Line(browser: browser, tab: tab, tools: .shared, gap: gap)
        }
    }

    #if DEBUG
    /// What a bar on screen shows in its field, for the bench to ask; nil
    /// with none up.
    static var shown: String?
    #endif

    /// The page on screen, never one only on its way: a page can start a
    /// load of another site's address and stall it, and that address must
    /// not stand under what is still its own (see Tab.restAddress). Without
    /// the name and password an address can carry before its host, which
    /// are a secret, or a way to dress one host as another.
    static func address(of tab: Tab) -> String {
        guard let url = tab.restAddress else { return "" }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user != nil || parts.password != nil else { return url.absoluteString }
        parts.user = nil
        parts.password = nil
        return parts.string ?? ""
    }

    private struct Line: View {
        let browser: Browser
        @ObservedObject var tab: Tab
        @ObservedObject var tools: DevTools
        let gap: CGFloat
        @FocusState private var editing: Bool

        private var window: ObjectIdentifier { ObjectIdentifier(browser) }
        private var address: String { DeveloperBar.address(of: tab) }
        private var shown: String { tools.drafts[window] ?? address }
        private var report: DevTools.Report? { tools.report(for: tab) }

        /// The field: the page's address until it is typed in.
        private var text: Binding<String> {
            Binding(get: { shown }, set: { tools.drafts[window] = $0 })
        }

        /// Nothing at all for a tab without Developer Mode: the page keeps
        /// the room.
        var body: some View {
            if tools.isOn(tab) { bar }
        }

        private var bar: some View {
            HStack(spacing: 2) {
                field
                if let report { readings(report) }
                tool("arrow.clockwise.circle", "Reload Without Cache",
                     help: "Reload this page, fetching everything again rather than from the cache.") {
                    tab.reload(fromOrigin: true)
                }
                tool("doc.plaintext", "View Source", help: "Open this page's source as plain text in a new tab.") {
                    DevTools.viewSource(of: tab, in: browser)
                }
                tool("hammer", "Web Inspector", help: "Show or hide the Web Inspector for this page (⌥⌘I).") {
                    browser.toggleInspector()
                }
            }
            .padding(.horizontal, 3)
            .frame(height: 34)
            .frame(maxWidth: .infinity)
            .background(Palette.ground)
            .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
            .padding(.top, gap)
            .onAppear { DevTools.attach(tab) }
            .onChange(of: tab.id) { DevTools.attach(tab) }
            .onChange(of: editing) { _, now in if !now { tools.drafts[window] = nil } }
            #if DEBUG
            .onAppear { DeveloperBar.shown = shown }
            .onChange(of: shown) { _, now in DeveloperBar.shown = now }
            .onDisappear { DeveloperBar.shown = nil }
            #endif
        }

        private var field: some View {
            TextField("Address", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Palette.ink)
                .focused($editing)
                .onSubmit {
                    if DevTools.go(shown, in: tab) {
                        tools.drafts[window] = nil
                        editing = false
                    } else {
                        NSSound.beep()
                    }
                }
                .onExitCommand {
                    tools.drafts[window] = nil
                    editing = false
                }
                .padding(.horizontal, 9)
                .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
                .background(editing ? Palette.wash : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
                .accessibilityLabel("Address of this tab")
                .help("This tab's address. Edit it and press Return to go there; Escape puts it back.")
        }

        /// What the page answered and how long it took, then its errors,
        /// which open the Inspector at its console.
        @ViewBuilder
        private func readings(_ report: DevTools.Report) -> some View {
            let said = [report.status.map(String.init), report.milliseconds.map { "\($0) ms" }]
                .compactMap { $0 }.joined(separator: " · ")
            if !said.isEmpty {
                Text(said)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(report.status.map { $0 >= 400 } == true ? Palette.unsafe : Palette.muted)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .help("The page's HTTP status, and its load time from the start of the navigation to the end of loading.")
            }
            Button { browser.showConsole() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12))
                    Text("\(report.errors)")
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                }
                .foregroundStyle(report.errors > 0 ? Palette.unsafe : Palette.muted)
                .padding(.horizontal, 8)
                .frame(minWidth: 40, minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(report.errors) script errors")
            .help("Script errors on this page: uncaught errors, unhandled rejections and console.error. Click to open the console.")
        }

        private func tool(_ icon: String, _ label: String, help: String, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(tab.isWeb ? Palette.muted : Palette.faint)
                    .frame(width: 32, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!tab.isWeb)
            .accessibilityLabel(label)
            .help(help)
        }
    }
}
