import AppKit

// Links from elsewhere. A click in Mail, in Slack, in a PDF — macOS hands the
// address to whichever app owns http, and this is how that app takes it.
//
// The bundle says it owns http and https (build.sh writes that into the
// plist); this is the other half. Addresses can arrive before the window has
// been built, so they wait here until the browser says it is ready for them.

final class Links: NSObject, NSApplicationDelegate {
    /// Where an address goes once there is somewhere for it to go.
    private static var deliver: ((URL) -> Void)?
    /// Addresses that arrived first.
    private static var waiting: [URL] = []
    /// The window in front's, or the first one's, once there is one.
    @MainActor static var window: NSWindow? { Browsers.front?.window ?? Browsers.primary?.window }
    /// Whether the window has been asked for on a link's behalf (summon).
    private static var summoned = false
    /// Whether the app has finished launching: a link that comes before
    /// then is what launched it (see keepWindowsAway).
    private(set) static var launched = false
    /// When the app was last shown after ⌘H, and last brought in front
    /// (see watchShowing).
    private static var shownAt: Date?
    private static var activatedAt: Date?
    private static var watching: [Any] = []
    /// A first quit waits for an import worker to remove its temporary files.
    /// AppKit calls us again when that cleanup has finished.
    private var terminationPending = false

    @MainActor private static var askingToQuit = false

    /// Only the user's Quit command asks; updater and system termination
    /// still go straight through the existing cleanup below.
    @MainActor static func shouldQuit() -> Bool {
        guard !askingToQuit else { return false }
        guard Store.settings.bool(forKey: Preferences.confirmQuitKey) else { return true }
        askingToQuit = true
        defer { askingToQuit = false }
        let alert = NSAlert()
        alert.messageText = "Quit Search?"
        alert.informativeText = "Your windows and tabs will close."
        alert.addButton(withTitle: "Quit").keyEquivalent = ""
        let cancel = alert.addButton(withTitle: "Cancel")
        alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
        // Making Cancel the Return default replaces its Escape equivalent.
        let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === alert.window, event.keyCode == 53 else { return event }
            cancel.performClick(nil)
            return nil
        }
        defer { if let escape { NSEvent.removeMonitor(escape) } }
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Quitting closes every window on the way out; that isn't a window
    /// closed for good, whose tabs would go (see Browsers.closing).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let waiting = MainActor.assumeIsolated { Browser.cancelAllFileImports() }
        guard waiting else {
            terminationPending = false
            // Only once the quit goes ahead: while it waits on an import,
            // a window closed is closed for good.
            MainActor.assumeIsolated { Browsers.quitting = true }
            return .terminateNow
        }
        if !terminationPending {
            terminationPending = true
            Task { @MainActor in
                // Five seconds at most: an import stuck on a slow disk
                // doesn't keep Search from quitting.
                let until = Date().addingTimeInterval(5)
                while Browser.hasActiveFileImports, Date() < until {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                self.terminationPending = false
                sender.terminate(nil)
            }
        }
        // Returning from AppKit's first terminate call lets MainActor finish
        // the worker continuation and remove it from Browser's registry.
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Every window, and windows.json (see Windows.swift).
        Browsers.flush()
        // And the bookmarks or downloads list saved a moment ago, still on
        // their way to the disk.
        Disk.drain()
    }

    /// The nearest thing to a crash reporter a browser with no server can
    /// have: nothing is sent anywhere, but a beta with no record of what
    /// went wrong is a beta nobody can fix. One line, appended, so it
    /// survives the crash that is about to end the process.
    static func watchForTrouble() {
        NSSetUncaughtExceptionHandler { exception in
            let line = "\(Date()) — \(exception.name.rawValue): \(exception.reason ?? "?")\n"
                + exception.callStackSymbols.joined(separator: "\n") + "\n\n"
            let file = Store.file("crash.log")
            if let handle = FileHandle(forWritingAtPath: file.path) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8) ?? Data())
                handle.closeFile()
            } else {
                try? FileManager.default.createDirectory(at: Store.folder, withIntermediateDirectories: true)
                try? line.write(to: file, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Addresses come in as Apple Events, one each. Taking them straight
    /// from the event manager keeps them out of SwiftUI's hands: left to it,
    /// every address handed at launch had the window presented afresh, and
    /// five of them meant five rebuilds of the content before the window
    /// had shown once.
    func applicationWillFinishLaunching(_ notification: Notification) {
        // The proxy, before anything can fetch. It is read when BrowserProxy
        // is first asked for, and until then Search's own requests would go
        // out directly: making a store happens to ask for it early on
        // macOS 15.4, but on 14 the first update check can beat it.
        MainActor.assumeIsolated { _ = BrowserProxy.shared }
        Links.watchForTrouble()
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handle(getURL:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL)
        )
        Links.watchShowing()
        // A test run takes no links from outside (see handle), so it is
        // handed one this way to launch with, taken where the Apple Event
        // would be (Tests/little_window.py).
        if Store.testing, let text = ProcessInfo.processInfo.environment["SEARCH_LINK"], let url = URL(string: text) {
            Links.take(url)
        }
    }

    /// A launch macOS doesn't call a plain one — started hidden, as `open -j`
    /// or anything asking for a hidden launch does — SwiftUI treats like the
    /// launch a link makes below: it leaves its window to whatever the launch
    /// came for, and nothing comes. The app ran with no window at all. The
    /// window is asked for here instead; started hidden, it stays hidden
    /// with the app until the app is shown.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI opens its window at launch, a link's launch included, and
        // asks nobody first (applicationShouldOpenUntitledFile isn't
        // consulted). A launch made for a small window came to read it alone,
        // and one made for the panel that asks which space, to choose one
        // (see little), so the browser's windows are put away as they come:
        // here, before the first is drawn, once more a turn later, and as
        // each is dressed. Open, with their tabs, and written down as they
        // were, until one is wanted (see Browsers.keepAway).
        MainActor.assumeIsolated { Browsers.putAway() }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                Browsers.putAway()
                Links.launched = true
                LinkChooserPanel.shared.launched()
            }
        }
        // What an import left in the temporary folder when Search stopped
        // in the middle of it — a Safari export's passwords in the clear
        // among it — goes (Security).
        DispatchQueue.global(qos: .utility).async { ImportFile.sweepScratch() }
        Trim.start()
        MainActor.assumeIsolated {
            Shared.prefs.followFile()
            // The address field from any app, once asked for (Launcher.swift).
            Launcher.shared.start()
            // Live folders fetched, and kept fresh (LiveFolders.swift).
            LiveFolders.start()
        }
        let plain = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        guard !plain else { return }
        DispatchQueue.main.async {
            guard !NSApp.windows.contains(where: { $0.contentView != nil && !($0 is NSPanel) }) else { return }
            Links.summon()
        }
    }

    @objc private func handle(getURL event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        // A test run takes nothing from outside it: an address from another
        // app would bring a window forward. The bench hands links in itself.
        guard !Store.testing else { return }
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: text), Links.takes(url)
        else { return }
        let sender = Self.sender(of: event)
        Links.take(url, sender: sender?.localizedName, pid: sender?.processIdentifier)
    }

    /// The app a link was clicked in, for the panel that asks which space it
    /// opens in: its name, and where Esc goes back to. Nil when the event
    /// doesn't say.
    private static func sender(of event: NSAppleEventDescriptor) -> NSRunningApplication? {
        guard let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value, pid > 0
        else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }

    /// macOS shows a hidden app (⌘H), and brings it in front, about 40 ms
    /// before it hands it a link: by the time the link comes the app is
    /// neither hidden nor behind, so when it last was is kept here.
    private static func watchShowing() {
        let center = NotificationCenter.default
        watching = [
            center.addObserver(forName: NSApplication.didUnhideNotification, object: nil, queue: .main) { _ in
                shownAt = Date()
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                activatedAt = Date()
            },
        ]
    }

    /// Whether a link came while the app was hidden, or behind another app:
    /// it is so now, or stopped being so less than a second ago.
    static func cameWhile(_ now: Bool, endedAgo seconds: TimeInterval?) -> Bool {
        now || (seconds ?? .infinity) < 1
    }

    /// A link that came while the app was hidden (⌘H).
    @MainActor static var cameWhileHidden: Bool {
        cameWhile(NSApp.isHidden, endedAgo: since(shownAt))
    }

    /// A link that brought the app in front: one that launched it, or came
    /// while another app was in front.
    @MainActor static var broughtForward: Bool {
        !launched || cameWhile(!NSApp.isActive, endedAgo: since(activatedAt))
    }

    private static func since(_ date: Date?) -> TimeInterval? {
        date.map { Date().timeIntervalSince($0) }
    }

    /// Files and anything else the system opens with the app: an address, or
    /// a page on this Mac — an .html or .xhtml double-clicked in the Finder
    /// once Search is the Mac's browser (it says it can open them, see
    /// build.sh), which this used to drop without a word.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !Store.testing else { return }
        for url in urls where url.isFileURL || Links.takes(url) {
            Links.take(url)
        }
    }

    /// A page handed off from your iPhone or another Mac, Search being the
    /// default browser: opened as a link from another app is, and only an
    /// http or https address (see Handoff.incoming). A test run takes none.
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard !Store.testing, let url = Handoff.incoming(userActivity) else { return false }
        Links.take(url)
        return true
    }

    /// The Dock icon clicked with the window closed: bring the window back
    /// rather than doing nothing, which is what a hidden-title-bar SwiftUI
    /// window does by default.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // A test run started hidden stays so: another launch of the same app
        // (`open -n` of a second probe) can reach it as a reopen, and nothing
        // is brought back, made or brought forward for it.
        guard !Store.testing else { return false }
        // The small window on screen counts as a window to macOS; the
        // browser's, kept away behind it, are what the Dock icon is for.
        if !flag || Browsers.keptAway { Browsers.ensureWindow() }
        return true
    }

    /// Closing the last window leaves the app running, as Safari and Chrome
    /// do (#327): the Dock icon, ⌘N or a link brings a window back, with its
    /// tabs. Its session is written as it closes (see Browsers.closing).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// New Window in the Dock icon's menu, as every browser has it.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "New Window", action: #selector(newWindow), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func newWindow() {
        MainActor.assumeIsolated { Browsers.newWindow() }
    }

    /// The browser, once it has a window. Anything that came earlier is
    /// handed over now — but none of it before the window is on screen.
    ///
    /// Five addresses at launch used to mean five web views built before the
    /// first frame, and a window that took a second to appear instead of a
    /// third of one. Now the window comes first; the first page goes into
    /// the blank tab that is already there, and the others fill in behind
    /// it, a few frames apart, in the order they came.
    @MainActor
    static func hand(to browser: Browser) {
        // Only the first window's arrival starts the delivery; the others
        // find it running.
        guard deliver == nil else { return }
        deliver = { url in
            land(url)
            comeForward()
        }
        let early = waiting
        waiting = []
        guard let first = early.first else { return }
        onceShown { [weak browser] in
            guard let browser else { return }
            (browser.routed(first) ?? browser).arrive(first)
            comeForward()
            for (n, url) in early.dropFirst().enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 * Double(n + 1)) { [weak browser] in
                    guard let browser else { return }
                    // One a rule sends to a space opens there, in front.
                    if let routed = browser.routed(url) {
                        routed.open(url, foreground: true)
                    } else {
                        browser.open(url, foreground: false, atEnd: true, mayWait: true)
                    }
                }
            }
        }
    }

    /// An address from outside the window — a link from another app, or what
    /// was typed into the address field raised from one (Launcher.swift) —
    /// into the window in front, or one brought back for it: it lands where
    /// you are, not in the first window. Or the window, in its space, a rule
    /// of Settings › Spaces & Pins › Send links to a space sends it to (see
    /// SpaceRoutes.swift). The window it went to, which is left for the
    /// caller to bring the app forward to.
    @MainActor
    @discardableResult
    static func land(_ url: URL) -> Browser {
        let front = Browsers.ensureWindow()
        let browser = front.routed(url) ?? front
        arrive(url, in: browser)
        return browser
    }

    /// A link in the space chosen for it (see LinkChooser), with that
    /// space's sign-ins from its first request: in a small window, or a tab
    /// of a window showing that space. False when the space is gone or no
    /// window can show it: it opens nowhere else.
    @MainActor
    static func open(_ url: URL, in space: UUID, little: Bool) -> Bool {
        if little {
            guard let profile = Spaces.known[space]?.profileID else { return false }
            let front = Browsers.frontBrowser
            let browser = front.profileID == profile ? front : Browsers.outOfSight(profile: profile)
            LittleWindow.show(url, for: browser, space: space)
            return true
        }
        guard let browser = Browsers.window(showing: space) else { return false }
        arrive(url, in: browser)
        comeForward()
        return true
    }

    /// In a tab of `browser`, with its window in front.
    @MainActor
    private static func arrive(_ url: URL, in browser: Browser) {
        browser.arrive(url)
        // Put away in the Dock, it stayed there: bringing a window to the
        // front doesn't take it out (#95).
        if let window = browser.window, window.isMiniaturized { window.deminiaturize(nil) }
        // A hidden probe's window stays out of sight.
        if !(Store.testing && NSApp.isHidden) { browser.window?.makeKeyAndOrderFront(nil) }
    }

    /// Runs once a window is actually showing, and one turn of the run loop
    /// after that, so the frame is on the screen before the work starts.
    /// Gives up waiting after a second or so and runs anyway — a launch
    /// started hidden has a window nobody can see yet.
    @MainActor
    static func onceShown(_ then: @escaping () -> Void, tries: Int = 0) {
        let shown = NSApp.windows.contains { $0.isVisible && $0.contentView != nil }
        if shown || tries > 40 {
            DispatchQueue.main.async(execute: then)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { onceShown(then, tries: tries + 1) }
        }
    }

    /// In front of the app the link was clicked in, the way a browser comes
    /// forward for Mail. Since macOS 14 an app is let in front when the app
    /// it is asked by hands the front over, and asks with `activate()`.
    /// Not every app hands it over: a link clicked in Notion, and in other
    /// apps built on Electron, left Search behind them. So if Search still
    /// isn't in front a moment later, it asks again the way it did before
    /// macOS 14.
    ///
    /// `lookedAt`: a test world opened to be looked at (./fresh.sh, with no
    /// script driving it) comes forward too — the launcher's Return there is
    /// how the launcher is tried by hand. Never one the bench drives.
    @MainActor
    static func comeForward(lookedAt: Bool = false) {
        // Never a test run's: a probe started hidden stays off every screen.
        guard !Store.testing || (lookedAt && !Launcher.benchDriven) else { return }
        guard #available(macOS 14, *) else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard !NSApp.isActive else { return }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// A link as another app hands one over, for the bench.
    static func arrived(_ url: URL, sender: String? = nil) { take(url, sender: sender) }

    /// What another app may hand over: a web address, an email link once
    /// Search is the Mac's email app (build.sh declares mailto), or a page on
    /// this Mac as an address. Python's webbrowser, and the apps built on it
    /// that open their local page through a file that sends you on to
    /// localhost (Jupyter's way), hands a file:// address to the default
    /// browser with "open location", not as a file to open: dropped here,
    /// nothing opened (#775), where Safari and Firefox open it.
    private static func takes(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        return scheme.hasPrefix("http") || scheme == "mailto" || url.isFileURL
    }

    private static func take(_ url: URL, sender: String? = nil, pid: pid_t? = nil) {
        // An email link: the webmail's compose page, which then goes where
        // any link from another app goes — a tab, or a small window for
        // whoever chose that. With no webmail chosen, the next app that
        // takes email links, never Search again (see Mail.handToSystem).
        if url.scheme?.lowercased() == "mailto" {
            MainActor.assumeIsolated {
                if let compose = Mail.compose(for: url) {
                    if Store.testing { Mail.seen.append("app: " + compose.absoluteString) }
                    take(compose, sender: sender, pid: pid)
                } else {
                    Mail.handToSystem(url)
                }
            }
            return
        }
        if MainActor.assumeIsolated({ little(url, sender: sender, pid: pid) }) { return }
        if let deliver {
            deliver(url)
        } else {
            waiting.append(url)
            DispatchQueue.main.async { summon() }
        }
    }

    /// In a small window of its own, for whoever chose that (see
    /// Little.swift), and nothing else: the browser's window stays where it
    /// is — closed, in the Dock, behind another app, or never opened by a
    /// launch this link made. It went through `deliver`, which brings a
    /// window back first, so the browser came up behind the small window
    /// every time. Open in Search is what brings it now.
    ///
    /// Or, for whoever turned on asking which space (see
    /// LinkChooserPanel.swift), nowhere yet: the panel asks first, and the
    /// window stays where it is unless a tab is chosen there.
    @MainActor
    private static func little(_ url: URL, sender: String?, pid: pid_t?) -> Bool {
        let prefs = Shared.prefs
        // A site sent to a space opens there, with that space's sign-ins.
        if SpaceRoutes.space(for: url) != nil { return false }
        if prefs.littleLinks, prefs.littleFindsTabs, goToOpen(url) { return true }
        if asksSpace(for: url) {
            keepWindowsAway()
            LinkChooserPanel.shared.ask(url, sender: sender, pid: pid)
            return true
        }
        guard prefs.littleLinks else { return false }
        openLittle(url)
        return true
    }

    /// Which space a web address opens in, asked before anything loads, for
    /// whoever turned that on: while there is more than one space, in all
    /// the profiles, to choose from. With one, the link goes as it always did.
    @MainActor
    private static func asksSpace(for url: URL) -> Bool {
        let prefs = Shared.prefs
        // The count last: it reads every profile's spaces from disk.
        return prefs.asksSpaceForLinks && prefs.usesSpaces && ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            && LinkChooserPanel.allRows.count > 1
    }

    /// A small window for `url`, and the browser's windows left where they
    /// are: for a link from another app, and for the address field from
    /// any app with its small window asked for (Launcher.submit).
    @MainActor
    static func openLittle(_ url: URL, for asked: Browser? = nil) {
        keepWindowsAway()
        // The space and sign-ins of the window in front, on screen or not.
        let browser = asked.flatMap { !$0.isPopup ? $0 : nil } ?? Browsers.frontBrowser
        LittleWindow.show(url, for: browser)
    }

    /// The browser's windows kept away for a link that launched the app, as
    /// a launch's are, or one that came while it was hidden (⌘H): the app is
    /// shown again with every window it had (see watchShowing), and the
    /// browser's came up beside the small window or the panel, as if the
    /// link had opened twice.
    @MainActor
    private static func keepWindowsAway() {
        guard !launched || cameWhileHidden else { return }
        Browsers.keepAway()
        Browsers.putAway()
    }

    /// The page already open, for whoever asked for that in Settings: a
    /// small window that has it comes forward, or a tab that has it, in its
    /// window, the window in front looked in first. Only each window's
    /// space on screen, as the address field's open pages are. False when
    /// none has it.
    @MainActor
    private static func goToOpen(_ url: URL) -> Bool {
        if let little = LittleWindow.all.last(where: { Browser.samePage(url, $0.tab.address) }) {
            little.front()
            return true
        }
        let windows = [Browsers.front].compactMap { $0 } + Browsers.all.reversed()
        for browser in windows where browser.isOpen && !browser.isPopup {
            guard let tab = browser.tabs.first(where: { Browser.samePage(url, $0.address) }) else { continue }
            // Windows a small window's launch kept off screen come back
            // first, all of them, as Open in Search brings them.
            Browsers.bringBack()
            browser.bringForward(tab.id)
            comeForward()
            return true
        }
        return false
    }

    /// A link that launches the app arrives as an Apple Event, taken above,
    /// and SwiftUI — seeing a launch that came to open something rather than
    /// a plain one — leaves its window for that event to open. It never sees
    /// the event, so nothing opened it: every link clicked in another app
    /// while Search was closed launched it with no window and the page
    /// nowhere. SwiftUI's delegate is asked instead for what a plain launch
    /// gets, its window; a single window, so asking twice can't make two.
    @MainActor
    private static func summon() {
        guard deliver == nil, window == nil, !summoned else { return }
        summoned = true
        _ = NSApp.delegate?.applicationOpenUntitledFile?(NSApp)
    }

    /// ⌘⇧F, the Help menu, and the About page all come here: a draft, in
    /// Mail, that already knows what build this is. The person still reads
    /// it and presses send themselves — nothing here sends anything.
    static func writeFeedback() {
        var text = URLComponents()
        text.scheme = "mailto"
        text.path = "hello@searchbrowser.app"
        text.queryItems = [
            URLQueryItem(name: "subject", value: "Search feedback — \(Updater.version) (\(Updater.build))"),
            URLQueryItem(name: "body", value: "\n\n—\nSearch \(Updater.version), build \(Updater.build), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"),
        ]
        guard let url = text.url else { return }
        // With a webmail chosen, its compose page, in a tab of the window in
        // front: no round trip through macOS, which may not send email
        // links here at all.
        let compose = MainActor.assumeIsolated { Mail.compose(for: url) }
        if let compose {
            MainActor.assumeIsolated {
                if Store.testing { Mail.seen.append("feedback: " + compose.absoluteString) }
                land(compose)
                comeForward()
            }
            return
        }
        // A test run opens no other app (Tests/webmail.py).
        if Store.testing { MainActor.assumeIsolated { Mail.seen.append("feedback: system") }; return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - being the browser

    private static let probe = URL(string: "https://example.com")!

    /// True when this app is where links from other apps go.
    static var isDefault: Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// Asks macOS to send http and https here. The system puts up its own
    /// confirmation; the answer arrives through `done`, on the main thread.
    static func becomeDefault(_ done: @escaping (Bool) -> Void) {
        let app = Bundle.main.bundleURL
        let group = DispatchGroup()
        var worked = true
        for scheme in ["http", "https"] {
            group.enter()
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme) { error in
                if error != nil { worked = false }
                group.leave()
            }
        }
        group.notify(queue: .main) { done(worked) }
    }
}
