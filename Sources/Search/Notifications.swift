import AppKit
import UserNotifications
import WebKit

// Web notifications (#328).
//
// A site asks, and you answer on a card over its own page, as for the camera
// (see Browser.askedForNotifications); the answer is kept per origin with
// the others, under "capture.", and Forget choices takes it back. A private
// tab is never asked and keeps nothing: it is simply refused.
//
// What a site then sends is posted as a Mac notification, named by the site
// and wearing its icon. A click brings the site's tab back to the front, and
// the click or the dismissal goes back to the page's service worker, as in
// Chrome. WebKit hands the notifications of a service worker to the data
// store's delegate — not public, but asked for by name here, and if it isn't
// there nothing is posted and nothing breaks.
//
// A test run posts nothing: a real notification would land on the screen of
// whoever is working beside it. It keeps what it would have posted, for the
// bench.

@MainActor
final class SiteNotifications: NSObject {
    static let shared = SiteNotifications()

    /// What a test run would have posted, newest last.
    private(set) var recorded: [[String: String]] = []

    /// The store each shown notification came from, for its click.
    fileprivate var stores: [String: WKWebsiteDataStore] = [:]
    private var authorized = false

    // MARK: - choices

    static func key(_ origin: String) -> String { "capture.\(origin)|notifications" }

    /// Every origin answered, allowed or not.
    static var choices: [String: Bool] {
        var out: [String: Bool] = [:]
        for (key, value) in Store.settings.dictionaryRepresentation()
        where key.hasPrefix("capture.") && key.hasSuffix("|notifications") {
            guard let allowed = value as? Bool else { continue }
            out[String(key.dropFirst("capture.".count).dropLast("|notifications".count))] = allowed
        }
        return out
    }

    /// The sites allowed to send notifications, for Settings › Privacy.
    static var allowed: [String] { choices.filter(\.value).map(\.key).sorted() }

    static func forget(_ origin: String) {
        Store.settings.removeObject(forKey: key(origin))
        shared.objectWillChange.send()
    }

    // MARK: - WebKit

    /// Made the delegate of a store its tabs use (never a private tab's).
    func attach(_ store: WKWebsiteDataStore) {
        let setter = NSSelectorFromString("set_delegate:")
        guard store.responds(to: setter) else { return }
        store.perform(setter, with: self)
        if !Store.testing, UNUserNotificationCenter.current().delegate == nil {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    /// The first site allowed: macOS asks, once, whether Search may notify.
    func authorize() {
        guard !Store.testing, !authorized else { return }
        authorized = true
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        let site = UNNotificationCategory(identifier: "site", actions: [], intentIdentifiers: [], options: [.customDismissAction])
        UNUserNotificationCenter.current().setNotificationCategories([site])
    }

    private var on: Bool { Shared.prefs.siteNotifications }

    /// WebKit asks, as a store opens, what each site was told.
    @objc(notificationPermissionsForWebsiteDataStore:)
    nonisolated func permissions(_ store: WKWebsiteDataStore) -> NSDictionary {
        let choices = MainActor.assumeIsolated { on ? SiteNotifications.choices : [:] }
        return choices.mapValues { NSNumber(value: $0) } as NSDictionary
    }

    /// A service worker's notification.
    @objc(websiteDataStore:showNotification:)
    nonisolated func show(_ store: WKWebsiteDataStore, notification data: NSObject) {
        MainActor.assumeIsolated {
            let text = { (key: String) in (data.responds(to: NSSelectorFromString(key)) ? data.value(forKey: key) as? String : nil) ?? "" }
            let origin = text("origin")
            // Only an origin you allowed, and only while the switch is on.
            guard on, SiteNotifications.choices[origin] == true else { return }
            let id = (data.responds(to: NSSelectorFromString("identifier")) ? data.value(forKey: "identifier") as? NSObject : nil)
                .map { "\($0)" } ?? UUID().uuidString
            let dictionary = data.responds(to: NSSelectorFromString("dictionaryRepresentation"))
                ? data.perform(NSSelectorFromString("dictionaryRepresentation"))?.takeUnretainedValue() as? NSDictionary : nil
            stores[id] = store
            post(id: id, title: text("title"), body: text("body"), origin: origin, tag: text("tag"),
                 info: ["search.kind": "worker", "search.id": id, "search.origin": origin,
                        "search.data": dictionary ?? [:]])
        }
    }

    /// What a service worker's getNotifications() finds.
    @objc(websiteDataStore:getDisplayedNotificationsForWorkerOrigin:completionHandler:)
    nonisolated func displayed(_ store: WKWebsiteDataStore, origin: WKSecurityOrigin, completionHandler: @escaping ([NSDictionary]) -> Void) {
        let site = MainActor.assumeIsolated { Store.testing ? nil : Browser.origin(origin.protocol, origin.host, origin.port) }
        guard let site else { return completionHandler([]) }
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            let found = delivered.compactMap { note -> NSDictionary? in
                let info = note.request.content.userInfo
                guard info["search.kind"] as? String == "worker", info["search.origin"] as? String == site else { return nil }
                return info["search.data"] as? NSDictionary
            }
            completionHandler(found)
        }
    }

    /// clients.openWindow() from a notification's click: a tab in the window
    /// in front, only for a web address.
    @objc(websiteDataStore:openWindow:fromServiceWorkerOrigin:completionHandler:)
    nonisolated func openWindow(_ store: WKWebsiteDataStore, url: URL, origin: WKSecurityOrigin, completionHandler: @escaping (WKWebView?) -> Void) {
        MainActor.assumeIsolated {
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), !Store.testing else { return completionHandler(nil) }
            // A window whose space signs in with the worker's store: the page
            // it opens must be the same person's, not the front window's.
            let fits = Browsers.all.filter { !$0.isPopup && Spaces.store(for: $0.spaceID) === store }
            guard let browser = fits.first(where: { $0 === Browsers.front && $0.isOpen }) ?? fits.last(where: \.isOpen) ?? fits.first
            else { return completionHandler(nil) }
            let tab = browser.open(url, foreground: true)
            Browsers.show(browser)
            completionHandler(tab.web)
        }
    }

    // MARK: - posting

    func post(id: String, title: String, body: String, origin: String, tag: String, info: [String: Any]) {
        guard !Store.testing else {
            recorded.append(["title": title, "body": body, "origin": origin, "tag": tag, "kind": info["search.kind"] as? String ?? ""])
            return
        }
        let content = UNMutableNotificationContent()
        var info = info
        info["search.key"] = id
        content.title = title
        content.body = body
        let url = URL(string: origin)
        content.subtitle = url.map(SiteCard.site) ?? origin
        content.threadIdentifier = origin
        content.categoryIdentifier = "site"
        content.sound = .default
        content.userInfo = info
        if let host = url?.host(), let icon = Favicons.shared.cached(for: url),
           let file = SiteNotifications.iconFile(icon, host: host),
           let attachment = try? UNNotificationAttachment(identifier: "icon", url: file) {
            content.attachments = [attachment]
        }
        // A tag names a notification its site means to replace.
        let identifier = tag.isEmpty ? id : "tag|\(origin)|\(tag)"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    /// The site's icon as a file of its own each time: macOS moves an
    /// attachment's file into its own keeping.
    private static func iconFile(_ image: NSImage, host: String) -> URL? {
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Search notifications", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(host)-\(UUID().uuidString).png")
        return (try? png.write(to: file)) == nil ? nil : file
    }

    // MARK: - answered

    /// Clicked: the site's tab in front, and the click to its worker.
    func clicked(_ info: [AnyHashable: Any]) {
        let origin = info["search.origin"] as? String ?? ""
        let key = info["search.key"] as? String
        let from = key.flatMap { stores.removeValue(forKey: $0) }
        bringForward(origin, from: from)
        if info["search.kind"] as? String == "page", let id = (info["search.id"] as? String).flatMap(UInt64.init) {
            return PageNotifications.clicked(id)
        }
        guard info["search.kind"] as? String == "worker", let data = info["search.data"] as? NSDictionary else { return }
        SiteNotifications.tell(from ?? Store.websites, "_processPersistentNotificationClick:completionHandler:", data)
    }

    /// Dismissed: the worker hears its notification closed.
    func closed(_ info: [AnyHashable: Any]) {
        let from = (info["search.key"] as? String).flatMap { stores.removeValue(forKey: $0) }
        if info["search.kind"] as? String == "page", let id = (info["search.id"] as? String).flatMap(UInt64.init) {
            return PageNotifications.closed(id)
        }
        guard info["search.kind"] as? String == "worker", let data = info["search.data"] as? NSDictionary else { return }
        SiteNotifications.tell(from ?? Store.websites, "_processPersistentNotificationClose:completionHandler:", data)
    }

    private typealias Deliver = @convention(c) (AnyObject, Selector, NSDictionary, @escaping @convention(block) (Bool) -> Void) -> Void

    private static func tell(_ store: WKWebsiteDataStore, _ name: String, _ data: NSDictionary) {
        let selector = NSSelectorFromString(name)
        guard store.responds(to: selector), let method = class_getMethodImplementation(type(of: store), selector) else { return }
        unsafeBitCast(method, to: Deliver.self)(store, selector, data) { _ in }
    }

    /// The tab showing the site in front: one signed in with the store the
    /// notification came from if there is one, never a private tab.
    private func bringForward(_ origin: String, from store: WKWebsiteDataStore?) {
        let found = Browsers.all.filter { !$0.isPopup }.flatMap { browser in
            browser.tabs.filter { tab in
                guard !tab.shy, tab.store.isPersistent, let url = tab.address, let scheme = url.scheme, let host = url.host() else { return false }
                return Browser.origin(scheme, host, url.port ?? 0) == origin
            }.map { (browser, $0) }
        }
        // Failing that, a tab of the same profile: never one of another
        // profile, signed in as someone else (see Profiles.swift).
        guard let (browser, tab) = found.first(where: { $0.1.store === store })
            ?? found.first(where: { pair in store.map { s in Spaces.stores(of: pair.0.profileID).contains { $0 === s } } ?? true })
        else { return }
        browser.select(tab)
        Browsers.show(browser)
        NSApp.activate()
    }
}

extension SiteNotifications: UNUserNotificationCenterDelegate {
    /// Shown even with Search in front, as a browser's are.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        nonisolated(unsafe) let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if action == UNNotificationDismissActionIdentifier { SiteNotifications.shared.closed(info) }
                else { SiteNotifications.shared.clicked(info) }
            }
            completionHandler()
        }
    }
}

extension SiteNotifications: ObservableObject {}

// MARK: - a page's own notifications
//
// `new Notification(…)` from a page (no service worker) reaches the app only
// through WebKit's C notification provider: a table of callbacks set on the
// process pool's notification manager. Its functions are exported but not
// declared anywhere Swift can see, so they are looked up by name; if one is
// missing, no provider is set, and a page's notification is shown nowhere,
// as before. A service worker's still come through the store's delegate.

private typealias Ref = UnsafeMutableRawPointer

/// WebKit's C functions, each looked up by name.
private struct WebKitC {
    let pageContext: @convention(c) (Ref) -> Ref?
    let manager: @convention(c) (Ref) -> Ref?
    let setProvider: @convention(c) (Ref, UnsafeRawPointer) -> Void
    let title: @convention(c) (Ref) -> Ref?
    let body: @convention(c) (Ref) -> Ref?
    let tag: @convention(c) (Ref) -> Ref?
    let id: @convention(c) (Ref) -> UInt64
    let origin: @convention(c) (Ref) -> Ref?
    let originString: @convention(c) (Ref) -> Ref?
    let cfString: @convention(c) (CFAllocator?, Ref) -> Unmanaged<CFString>?
    let didShow: @convention(c) (Ref, UInt64) -> Void
    let didClick: @convention(c) (Ref, UInt64) -> Void
    let didClose: @convention(c) (Ref, Ref) -> Void
    let uint64: @convention(c) (UInt64) -> Ref?
    let uint64Value: @convention(c) (Ref) -> UInt64
    let array: @convention(c) (UnsafeMutablePointer<Ref?>, Int) -> Ref?
    let arraySize: @convention(c) (Ref) -> Int
    let arrayItem: @convention(c) (Ref, Int) -> Ref?
    let dictionary: @convention(c) () -> Ref?
    let setItem: @convention(c) (Ref, Ref, Ref) -> Bool
    let boolean: @convention(c) (Bool) -> Ref?
    let string: @convention(c) (CFString) -> Ref?
    let release: @convention(c) (Ref) -> Void
    /// Optional: a service worker's notification, which the store's
    /// delegate posts, is left alone here.
    let persistent: (@convention(c) (Ref) -> Bool)?

    static let loaded: WebKitC? = {
        let webkit = dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", RTLD_NOW)
        func f<T>(_ name: String) -> T? { dlsym(webkit, name).map { unsafeBitCast($0, to: T.self) } }
        guard let pageContext: @convention(c) (Ref) -> Ref? = f("WKPageGetContext"),
              let manager: @convention(c) (Ref) -> Ref? = f("WKContextGetNotificationManager"),
              let setProvider: @convention(c) (Ref, UnsafeRawPointer) -> Void = f("WKNotificationManagerSetProvider"),
              let title: @convention(c) (Ref) -> Ref? = f("WKNotificationCopyTitle"),
              let body: @convention(c) (Ref) -> Ref? = f("WKNotificationCopyBody"),
              let tag: @convention(c) (Ref) -> Ref? = f("WKNotificationCopyTag"),
              let id: @convention(c) (Ref) -> UInt64 = f("WKNotificationGetID"),
              let origin: @convention(c) (Ref) -> Ref? = f("WKNotificationGetSecurityOrigin"),
              let originString: @convention(c) (Ref) -> Ref? = f("WKSecurityOriginCopyToString"),
              let cfString: @convention(c) (CFAllocator?, Ref) -> Unmanaged<CFString>? = f("WKStringCopyCFString"),
              let didShow: @convention(c) (Ref, UInt64) -> Void = f("WKNotificationManagerProviderDidShowNotification"),
              let didClick: @convention(c) (Ref, UInt64) -> Void = f("WKNotificationManagerProviderDidClickNotification"),
              let didClose: @convention(c) (Ref, Ref) -> Void = f("WKNotificationManagerProviderDidCloseNotifications"),
              let uint64: @convention(c) (UInt64) -> Ref? = f("WKUInt64Create"),
              let uint64Value: @convention(c) (Ref) -> UInt64 = f("WKUInt64GetValue"),
              let array: @convention(c) (UnsafeMutablePointer<Ref?>, Int) -> Ref? = f("WKArrayCreate"),
              let arraySize: @convention(c) (Ref) -> Int = f("WKArrayGetSize"),
              let arrayItem: @convention(c) (Ref, Int) -> Ref? = f("WKArrayGetItemAtIndex"),
              let dictionary: @convention(c) () -> Ref? = f("WKMutableDictionaryCreate"),
              let setItem: @convention(c) (Ref, Ref, Ref) -> Bool = f("WKDictionarySetItem"),
              let boolean: @convention(c) (Bool) -> Ref? = f("WKBooleanCreate"),
              let string: @convention(c) (CFString) -> Ref? = f("WKStringCreateWithCFString"),
              let release: @convention(c) (Ref) -> Void = f("WKRelease")
        else { return nil }
        return WebKitC(pageContext: pageContext, manager: manager, setProvider: setProvider, title: title, body: body, tag: tag,
                       id: id, origin: origin, originString: originString, cfString: cfString, didShow: didShow,
                       didClick: didClick, didClose: didClose, uint64: uint64, uint64Value: uint64Value, array: array,
                       arraySize: arraySize, arrayItem: arrayItem, dictionary: dictionary, setItem: setItem,
                       boolean: boolean, string: string, release: release,
                       persistent: f("WKNotificationGetIsPersistent"))
    }()

    /// A WKString copied out, and the copy let go.
    func text(_ copied: Ref?) -> String {
        guard let copied else { return "" }
        defer { release(copied) }
        return cfString(nil, copied)?.takeRetainedValue() as String? ?? ""
    }

    /// A WKArray of one notification id.
    func ids(_ id: UInt64) -> Ref? {
        guard let one = uint64(id) else { return nil }
        defer { release(one) }
        var items: [Ref?] = [one]
        return array(&items, 1)
    }
}

/// The pages' own path, set once per notification manager.
@MainActor
enum PageNotifications {
    private static var managers: [Ref] = []

    /// WKNotificationProviderV0, laid out by hand: a version (int), the
    /// client's pointer, then its seven callbacks in WebKit's order.
    private static let provider: UnsafeMutableRawPointer = {
        let show: @convention(c) (Ref?, Ref?, UnsafeRawPointer?) -> Void = { page, note, _ in
            guard let page, let note else { return }
            MainActor.assumeIsolated { PageNotifications.show(page, note) }
        }
        let cancel: @convention(c) (Ref?, UnsafeRawPointer?) -> Void = { note, _ in
            guard let note else { return }
            MainActor.assumeIsolated { PageNotifications.cancel(note) }
        }
        let ignored: @convention(c) (Ref?, UnsafeRawPointer?) -> Void = { _, _ in }
        let permissions: @convention(c) (UnsafeRawPointer?) -> Ref? = { _ in
            // Handed across as an address: the dictionary is WebKit's from here.
            UnsafeMutableRawPointer(bitPattern: MainActor.assumeIsolated { PageNotifications.permissions().map { UInt(bitPattern: $0) } ?? 0 })
        }
        let clear: @convention(c) (Ref?, UnsafeRawPointer?) -> Void = { ids, _ in
            guard let ids else { return }
            MainActor.assumeIsolated { PageNotifications.clear(ids) }
        }
        let table = UnsafeMutableRawPointer.allocate(byteCount: 16 + 7 * 8, alignment: 8)
        table.storeBytes(of: Int32(0), toByteOffset: 0, as: Int32.self)
        table.storeBytes(of: nil, toByteOffset: 8, as: UnsafeRawPointer?.self)
        let callbacks: [UnsafeRawPointer] = [
            unsafeBitCast(show, to: UnsafeRawPointer.self), unsafeBitCast(cancel, to: UnsafeRawPointer.self),
            unsafeBitCast(ignored, to: UnsafeRawPointer.self), unsafeBitCast(ignored, to: UnsafeRawPointer.self),
            unsafeBitCast(ignored, to: UnsafeRawPointer.self), unsafeBitCast(permissions, to: UnsafeRawPointer.self),
            unsafeBitCast(clear, to: UnsafeRawPointer.self),
        ]
        for (index, callback) in callbacks.enumerated() {
            table.storeBytes(of: callback, toByteOffset: 16 + index * 8, as: UnsafeRawPointer.self)
        }
        return table
    }()

    private typealias PageRef = @convention(c) (AnyObject, Selector) -> Ref?

    private static func page(of web: WKWebView) -> Ref? {
        let selector = NSSelectorFromString("_pageRefForTransitionToWKWebView")
        guard web.responds(to: selector), let method = class_getMethodImplementation(type(of: web), selector) else { return nil }
        return unsafeBitCast(method, to: PageRef.self)(web, selector)
    }

    /// Set on the manager of a (not private) tab's page, once.
    static func provide(_ web: WKWebView) {
        guard let c = WebKitC.loaded, let page = page(of: web), let context = c.pageContext(page),
              let manager = c.manager(context), !managers.contains(manager) else { return }
        managers.append(manager)
        c.setProvider(manager, provider)
    }

    private static func origin(of note: Ref, _ c: WebKitC) -> String {
        guard let origin = c.origin(note), let url = URL(string: c.text(c.originString(origin))),
              let scheme = url.scheme, let host = url.host() else { return "" }
        return Browser.origin(scheme, host, url.port ?? 0)
    }

    private static func show(_ page: Ref, _ note: Ref) {
        guard let c = WebKitC.loaded, c.persistent?(note) != true,
              let context = c.pageContext(page), let manager = c.manager(context) else { return }
        let origin = origin(of: note, c)
        // Only a site you allowed, while the switch is on, and never from a
        // private tab, which shares the process pool but keeps nothing.
        let web = Web.pages.allObjects.first { self.page(of: $0) == page }
        guard Shared.prefs.siteNotifications, SiteNotifications.choices[origin] == true,
              let web, web.configuration.websiteDataStore.isPersistent else { return }
        let id = c.id(note)
        SiteNotifications.shared.post(id: "page|\(id)", title: c.text(c.title(note)), body: c.text(c.body(note)),
                                      origin: origin, tag: c.text(c.tag(note)),
                                      info: ["search.kind": "page", "search.id": String(id), "search.origin": origin])
        shown[id] = manager
        SiteNotifications.shared.stores["page|\(id)"] = web.configuration.websiteDataStore
        c.didShow(manager, id)
    }

    /// Each shown notification's manager, for its click and its close.
    private static var shown: [UInt64: Ref] = [:]

    /// notification.close() from the page.
    private static func cancel(_ note: Ref) {
        guard let c = WebKitC.loaded else { return }
        let id = c.id(note)
        forget(id)
        SiteNotifications.shared.stores["page|\(id)"] = nil
        closed(id)
    }

    /// Notifications WebKit is done with (their page went away).
    private static func clear(_ ids: Ref) {
        guard let c = WebKitC.loaded else { return }
        for index in 0..<c.arraySize(ids) {
            guard let item = c.arrayItem(ids, index) else { continue }
            let id = c.uint64Value(item)
            forget(id)
            shown[id] = nil
            SiteNotifications.shared.stores["page|\(id)"] = nil
        }
    }

    private static func forget(_ id: UInt64) {
        guard !Store.testing else { return }
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            let gone = delivered.filter { $0.request.content.userInfo["search.id"] as? String == String(id)
                && $0.request.content.userInfo["search.kind"] as? String == "page" }.map(\.request.identifier)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: gone)
        }
    }

    /// What each site was told, as WebKit asks for it (handed over, not kept).
    private static func permissions() -> Ref? {
        guard let c = WebKitC.loaded, let dictionary = c.dictionary() else { return nil }
        guard Shared.prefs.siteNotifications else { return dictionary }
        for (origin, allowed) in SiteNotifications.choices {
            guard let key = c.string(origin as CFString), let value = c.boolean(allowed) else { continue }
            _ = c.setItem(dictionary, key, value)
            c.release(key)
            c.release(value)
        }
        return dictionary
    }

    static func clicked(_ id: UInt64) {
        guard let c = WebKitC.loaded, let manager = shown[id] else { return }
        c.didClick(manager, id)
    }

    static func closed(_ id: UInt64) {
        guard let c = WebKitC.loaded, let manager = shown.removeValue(forKey: id), let ids = c.ids(id) else { return }
        c.didClose(manager, ids)
        c.release(ids)
    }
}
