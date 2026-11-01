import AppKit
import SwiftUI
import WebKit

// Screen recording for extensions (#218): Loom, Screencastify, Awesome
// Screenshot and the like.
//
// Chrome hands an extension a stream id from its own picker
// (desktopCapture.chooseDesktopMedia) and the stream for it from
// getUserMedia. WebKit has neither. What it has is getDisplayMedia, which
// shows the Mac's own picker, and which it refuses unless the call comes
// from a click being handled in a page that is on screen. So Shy stands
// in between. An extension's page asks through a channel that knows who is
// asking; Shy asks you, once per extension, whether it may record; brings
// the page on screen; and calls WebKit's getDisplayMedia in that page itself,
// which WebKit counts as a click. The Mac's picker follows, every time: it is
// the Mac, not Shy, that asks what to share. The stream stays in the page
// and is handed over as the answer to the extension's getUserMedia.
//
// While an extension records, a small pill says so and stops it
// (RecordingIndicator.swift, which shows what this watches).
//
// Nothing here uses ScreenCaptureKit or looks at other windows: WebKit's
// picker is the only way in, and it needs no Screen Recording permission.
// A test run never brings anything on screen and never shows the pill.

@available(macOS 15.4, *)
@MainActor
final class ExtensionCapture: NSObject, WKScriptMessageHandlerWithReply, ObservableObject {
    static let shared = ExtensionCapture()
    /// The name the pages post to (window.webkit.messageHandlers).
    static let channel = "shyCapture"

    override private init() {
        super.init()
        RecordingIndicator.shared.onStop = { [weak self] id in self?.stop(id) }
    }

    // MARK: - asking, once per extension

    static func key(_ id: String) -> String { "extensions.capture.\(id)" }
    static func allowed(_ id: String) -> Bool { Store.settings.bool(forKey: key(id)) }

    /// The extensions you let record, for Settings › Extensions.
    static var allowedIDs: [String] {
        Store.settings.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("extensions.capture.") }
            .map { String($0.dropFirst("extensions.capture.".count)) }
            .filter { allowed($0) }
            .sorted()
    }

    /// Taken back: asked again the next time it wants to record.
    static func forget(_ id: String) {
        Store.settings.removeObject(forKey: key(id))
        shared.refused.remove(id)
        shared.objectWillChange.send()
    }

    /// It may record: it says so in its manifest, or was given it since.
    static func declares(_ context: WKWebExtensionContext) -> Bool {
        let manifest = context.webExtension.manifest
        let required = manifest["permissions"] as? [String] ?? []
        let granted = Store.settings.stringArray(forKey: Extensions.grantKey("granted", context)) ?? []
        return required.contains("desktopCapture") || granted.contains("desktopCapture")
    }

    private var refused: Set<String> = []

    /// Yes from you: now, or before and you have just used this extension —
    /// its button or its line in the menu within the last minute (Loom's
    /// Start is in its menu over the page, which isn't one of its own), its
    /// popup or its pages within the last few seconds. Otherwise it is asked
    /// again: a remembered yes never lets an extension take the screen on
    /// its own.
    private func consent(_ context: WKWebExtensionContext) async -> Bool {
        let id = context.uniqueIdentifier
        let pressed = Extensions.pressed[id].map { Date().timeIntervalSince($0) < 60 } ?? false
        if ExtensionCapture.allowed(id), pressed || Extensions.justUsed(id) { return true }
        // Refused once, not asked again until Shy starts afresh: an
        // extension can't wear you down with the question.
        guard !refused.contains(id) else { return false }
        guard await (Extensions.owner(of: context) ?? Extensions.shared).ask(capture: context) else {
            refused.insert(id)
            return false
        }
        Store.settings.set(true, forKey: ExtensionCapture.key(id))
        objectWillChange.send()
        return true
    }

    // MARK: - stream ids

    /// A stream id handed to an extension: good once, for a minute, for that
    /// extension only.
    private struct Grant {
        let extensionID: String
        let made: Date
    }
    private var grants: [String: Grant] = [:]

    private static func token() -> String? {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// From the extension's worker, which has no page to record in: the id is
    /// given now, and the recording starts when one of its pages hands it to
    /// getUserMedia (see `consume`).
    func grant(for context: WKWebExtensionContext) async -> String {
        guard ExtensionCapture.declares(context), await consent(context), let token = ExtensionCapture.token() else { return "" }
        grants = grants.filter { Date().timeIntervalSince($0.value.made) < 60 }
        grants[token] = Grant(extensionID: context.uniqueIdentifier, made: Date())
        return token
    }

    // MARK: - the channel

    /// What the bench reads.
    private(set) var last: [String: String] = [:]

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else {
            return replyHandler(nil, "Not a request")
        }
        // Only the top of one of an extension's own pages, in a view of that
        // extension's: not a site framed in it, not its page framed in a site,
        // not another extension.
        guard let (context, web) = ExtensionCapture.sender(of: message) else {
            last = ["op": op, "refused": "sender"]
            return replyHandler(["error": "NotAllowedError", "message": "Not allowed here"], nil)
        }
        // The microphone or camera, from an offscreen document: WebKit holds
        // the request for as long as the page has no window, so one made to
        // record is lent to the pill first — the pill is up while it listens.
        // Any other extension page just goes on.
        if op == "lend" {
            guard let reasons = ExtensionOffscreen.reasons(of: web) else { return replyHandler(["ok": true], nil) }
            guard !reasons.isDisjoint(with: ["USER_MEDIA", "DISPLAY_MEDIA"]) else {
                return replyHandler(["error": "NotAllowedError", "message": "This offscreen document wasn't made to record"], nil)
            }
            lendAwhile(web)
            return replyHandler(["ok": true], nil)
        }
        Task { @MainActor in
            let answer = await self.answer(op, body, context: context, in: web)
            self.last = answer.mapValues { "\($0)" }.merging(["op": op]) { a, _ in a }
            replyHandler(answer, nil)
        }
    }

    static func sender(of message: WKScriptMessage) -> (WKWebExtensionContext, WKWebView)? {
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame, let web = message.webView, Browser.extensionScheme(origin.protocol),
              let url = web.url, url.scheme?.lowercased() == origin.protocol.lowercased(),
              url.host()?.lowercased() == origin.host.lowercased(),
              let context = Extensions.owner(of: web.configuration.webExtensionController)?.contexts.values.first(where: { $0.uniqueIdentifier.lowercased() == origin.host.lowercased() }),
              web.configuration.websiteDataStore.isPersistent
        else { return nil }
        return (context, web)
    }

    private func answer(_ op: String, _ body: [String: Any], context: WKWebExtensionContext, in web: WKWebView) async -> [String: Any] {
        guard ExtensionCapture.declares(context) || op == "display" else {
            return ["error": "NotAllowedError", "message": "It didn't ask to record your screen"]
        }
        // An offscreen document records only if it was made to.
        if let reasons = ExtensionOffscreen.reasons(of: web), reasons.isDisjoint(with: ["USER_MEDIA", "DISPLAY_MEDIA"]) {
            return ["error": "NotAllowedError", "message": "This offscreen document wasn't made to record"]
        }
        let video = body["video"] ?? true
        // Which picker: a screen, or a window. Chrome's sources in order of
        // preference, or getDisplayMedia's displaySurface.
        let sources = body["sources"] as? [String] ?? []
        let first = sources.first { $0 == "screen" || $0 == "window" || $0 == "tab" }
        let surface = body["surface"] as? String
        let window = first == "window" || first == "tab" || surface == "window" || surface == "browser"
        switch op {
        // chooseDesktopMedia, from a page: asked, and recorded right away in
        // that page, so a cancelled picker is an empty id, as in Chrome.
        case "choose", "display":
            guard await consent(context), let token = ExtensionCapture.token() else {
                return ["error": "NotAllowedError", "message": "Permission denied"]
            }
            return await record(in: web, token: token, video: video, window: window, context: context)
        // An id the worker was given, handed to getUserMedia in a page.
        case "consume":
            guard let token = body["token"] as? String, let grant = grants.removeValue(forKey: token),
                  grant.extensionID == context.uniqueIdentifier, Date().timeIntervalSince(grant.made) < 60
            else { return ["error": "NotAllowedError", "message": "Invalid state"] }
            return await record(in: web, token: token, video: video, window: window, context: context)
        default:
            return ["error": "NotSupportedError", "message": "Unknown request"]
        }
    }

    /// The page on screen, then WebKit's getDisplayMedia called in it.
    /// Pages where Shy's own call is under way, and the picker it asks
    /// for (1 a screen, 2 a window): WebKit's question about recording, from
    /// an extension's page, is yes only for these (see ExtensionPageDelegate).
    private var inFlight: [ObjectIdentifier: Int] = [:]

    /// WebKit asking, for an extension's page, whether it may show the
    /// picker: WKDisplayCapturePermissionDecision, 0 no, 1 a screen, 2 a
    /// window (the same in the WebKit this runs on and in WebKit's main).
    func displayDecision(for web: WKWebView) -> Int { inFlight[ObjectIdentifier(web)] ?? 0 }

    private func record(in web: WKWebView, token: String, video: Any, window: Bool, context: WKWebExtensionContext) async -> [String: Any] {
        // An offscreen document has no window: it is lent to the pill while
        // it records, so what makes WebKit count it as seen is what says it
        // is recording. A page in a tab is brought forward.
        let lend = ExtensionOffscreen.reasons(of: web) != nil
        if lend { await host(web) } else { await bringForward(web) }
        inFlight[ObjectIdentifier(web)] = window ? 2 : 1
        let answer = await force(in: web, token: token, video: video, context: context)
        inFlight[ObjectIdentifier(web)] = nil
        if lend, answer["ok"] as? Bool != true { giveBack(web) }
        return answer
    }

    private func force(in web: WKWebView, token: String, video: Any, context: WKWebExtensionContext) async -> [String: Any] {
        do {
            // Called by the app, so WebKit counts it as a click: the page's
            // own getDisplayMedia, kept by the shim before any of the
            // extension's code ran, is called at once, before any await.
            let result = try await web.callAsyncJavaScript(
                "return await globalThis[Symbol.for('shy.capture')](token, video);",
                arguments: ["token": token, "video": video], in: nil, contentWorld: .page)
            guard let reply = result as? [String: Any] else { return ["error": "AbortError", "message": "No answer"] }
            if reply["ok"] as? Bool == true {
                watch(web, id: context.uniqueIdentifier)
                return ["ok": true, "token": token]
            }
            return reply
        } catch {
            return ["error": "AbortError", "message": error.localizedDescription]
        }
    }

    /// Offscreen pages lent to the pill, until their recording ends.
    private var lent: Set<ObjectIdentifier> = []

    /// Lent for a request that may never start: given back if nothing is
    /// recording in it half a minute on.
    private func lendAwhile(_ web: WKWebView) {
        guard !lent.contains(ObjectIdentifier(web)) else { return }
        lent.insert(ObjectIdentifier(web))
        lendings += 1
        RecordingIndicator.shared.host(web)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self, weak web] in
            guard let self, let web, !ExtensionCapture.capturing(web) else { return }
            self.giveBack(web)
        }
    }

    /// How many times a page was lent, for the bench.
    private var lendings = 0

    private func host(_ web: WKWebView) async {
        lent.insert(ObjectIdentifier(web))
        lendings += 1
        RecordingIndicator.shared.host(web)
        guard !Store.testing else { return }
        for _ in 0..<20 {
            if web.window?.isVisible == true,
               (try? await web.evaluateJavaScript("document.visibilityState")) as? String == "visible" { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func giveBack(_ web: WKWebView) {
        guard lent.remove(ObjectIdentifier(web)) != nil else { return }
        RecordingIndicator.shared.release(web)
    }

    /// WebKit won't start a recording in a page that isn't on screen. Brought
    /// forward only after you said yes or just did something in Shy, and
    /// never in a test run.
    private func bringForward(_ web: WKWebView) async {
        guard !Store.testing else { return }
        for browser in Browsers.all {
            guard let tab = browser.tab(for: web) else { continue }
            browser.select(tab)
            Browsers.show(browser)
            break
        }
        for _ in 0..<20 {
            if web.window?.isVisible == true, web.window?.occlusionState.contains(.visible) == true,
               (try? await web.evaluateJavaScript("document.visibilityState")) as? String == "visible" { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - what is recording

    /// Pages of extensions that asked to capture, watched for as long as they
    /// last — whatever the extension's own code does, the pill says it.
    @MainActor private final class Watched {
        weak var web: WKWebView?
        /// The extension that asked; nil for a tab watched only for sharing
        /// its screen, which the pill names by its site.
        var extensionID: String?
        var capturing = false
        init(_ web: WKWebView, _ id: String?) { self.web = web; self.extensionID = id }

        var id: String { extensionID ?? "site:" + (web?.url?.host() ?? "") }

        /// What counts: everything an extension captures; for a site, only
        /// its screen — its camera and microphone have their own marks.
        var live: Bool {
            guard let web else { return false }
            return extensionID == nil ? ExtensionCapture.screen(web) : ExtensionCapture.capturing(web)
        }
    }
    private var watched: [ObjectIdentifier: Watched] = [:]
    private static let keys = ["cameraCaptureState", "microphoneCaptureState", "_displayCaptureState"]

    /// Every camera or microphone question passes here (Browser.askedForCapture,
    /// for tabs, the popup and offscreen documents): one from an extension —
    /// its page, or its frame in a site, as a camera bubble is — is watched.
    func watchCapture(_ web: WKWebView, frame: WKFrameInfo) {
        let asker = frame.securityOrigin
        let id = Browser.extensionScheme(asker.protocol) ? asker.host : web.url.flatMap(Browser.extensionHost)
        guard let id, !id.isEmpty else { return }
        watch(web, id: id)
    }

    /// Every tab, a website's included: sharing its screen puts up the pill
    /// too — a site doing it itself (Meet), or an extension's frame in it
    /// (Loom's menu), which goes through the site's page. Nothing changes in
    /// what WebKit asks a website.
    func watchScreen(_ web: WKWebView) {
        guard web.responds(to: NSSelectorFromString("_displayCaptureState")) else { return }
        register(web, id: nil)
    }

    func watch(_ web: WKWebView, id: String) { register(web, id: id) }

    private func register(_ web: WKWebView, id: String?) {
        let key = ObjectIdentifier(web)
        if let entry = watched[key], entry.web != nil {
            if entry.extensionID == nil { entry.extensionID = id }
            return changed()
        }
        watched[key] = Watched(web, id)
        for path in ExtensionCapture.keys where path != "_displayCaptureState" || web.responds(to: NSSelectorFromString(path)) {
            web.addObserver(self, forKeyPath: path, options: [], context: nil)
        }
        changed()
    }

    nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                           change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async { MainActor.assumeIsolated { ExtensionCapture.shared.changed() } }
    }

    /// One extension's captures, in words.
    struct Recording: Equatable, Identifiable {
        let id: String
        let name: String
        /// A website sharing its screen, rather than an extension.
        let site: Bool
        let screen: Bool
        let camera: Bool
        let microphone: Bool

        var what: String {
            if site { return "is sharing your screen" }
            if screen { return "is recording your screen" }
            if camera && microphone { return "is using your camera and microphone" }
            return camera ? "is using your camera" : "is using your microphone"
        }
    }

    @Published private(set) var recordings: [Recording] = []

    static func screen(_ web: WKWebView) -> Bool {
        guard web.responds(to: NSSelectorFromString("_displayCaptureState")) else { return false }
        return (web.value(forKey: "_displayCaptureState") as? Int ?? 0) != 0
    }

    /// Whether this page is recording anything, for Sleep.
    static func capturing(_ web: WKWebView) -> Bool {
        screen(web) || web.cameraCaptureState != .none || web.microphoneCaptureState != .none
    }

    private func changed() {
        var by: [String: Recording] = [:]
        for (key, entry) in watched {
            // A page gone: WebKit's views let their observers go with them.
            guard let web = entry.web else { watched[key] = nil; continue }
            let now = entry.live
            // Stopped: an offscreen page lent to the pill goes back.
            if entry.capturing, !now { giveBack(web) }
            entry.capturing = now
            guard now else { continue }
            let before = by[entry.id]
            let site = entry.extensionID == nil
            by[entry.id] = Recording(
                id: entry.id, name: site ? (web.url.map(SiteCard.site) ?? "A page") : Browser.extensionName(entry.id),
                site: site,
                screen: (before?.screen ?? false) || ExtensionCapture.screen(web),
                camera: (before?.camera ?? false) || web.cameraCaptureState != .none,
                microphone: (before?.microphone ?? false) || web.microphoneCaptureState != .none)
        }
        let now = by.values.sorted { $0.name < $1.name }
        guard now != recordings else { return }
        recordings = now
        // The pill, and the mark on each recording tab (RecordingIndicator).
        RecordingIndicator.shared.update(now.map { RecordingLine(id: $0.id, name: $0.name, what: $0.what) },
                                         pages: now.flatMap { webViews(of: $0.id) })
    }

    /// The pages of an extension that are capturing now: for the mark on
    /// their tabs.
    func webViews(of id: String) -> [WKWebView] {
        watched.values.filter { $0.id == id && $0.live }.compactMap(\.web)
    }

    private typealias SetDisplay = @convention(c) (AnyObject, Selector, Int, (@convention(block) () -> Void)?) -> Void

    /// Stop: everything the extension is capturing ends, and its pages see
    /// their tracks end; for a site, its screen only.
    func stop(_ id: String) {
        for entry in watched.values where entry.id == id {
            guard let web = entry.web else { continue }
            let selector = NSSelectorFromString("_setDisplayCaptureState:completionHandler:")
            if web.responds(to: selector), let method = class_getMethodImplementation(type(of: web), selector) {
                unsafeBitCast(method, to: SetDisplay.self)(web, selector, 0, nil)
            }
            // A site's Stop ends only its screen: the call it is on goes on.
            guard entry.extensionID != nil else { continue }
            web.setCameraCaptureState(.none, completionHandler: nil)
            web.setMicrophoneCaptureState(.none, completionHandler: nil)
        }
    }

    /// The extension went away: what it records stops, and its ids with it.
    func purge(_ id: String) {
        stop(id)
        grants = grants.filter { $0.value.extensionID != id }
    }

    /// What the bench sees.
    var state: [String: Any] {
        ["grants": grants.count, "last": last,
         "recordings": recordings.map { ["id": $0.id, "what": $0.what] },
         "allowed": ExtensionCapture.allowedIDs,
         "pill": RecordingIndicator.shared.lines.map { "\($0.name) \($0.what)" },
         "lent": lent.count, "lendings": lendings,
         "watching": watched.values.filter { $0.web != nil }.count]
    }

    // MARK: - test runs

    /// WebKit's pretend camera, microphone and screen, so a test run records
    /// with no hardware and no macOS question. Never outside a test run.
    nonisolated static func mockDevices(_ preferences: WKPreferences) {
        guard Store.testing else { return }
        // WebKit's own pretend prompt stays: turned off, it grants without
        // asking Shy at all, and the question is what is being tested.
        set("_setMockCaptureDevicesEnabled:", true, in: preferences)
        set("_setGetUserMediaRequiresFocus:", false, in: preferences)
    }

    /// One of WebKit's preferences it doesn't make public, if it has it.
    nonisolated static func set(_ name: String, _ on: Bool, in preferences: WKPreferences) {
        let selector = NSSelectorFromString(name)
        guard preferences.responds(to: selector), let method = class_getMethodImplementation(type(of: preferences), selector) else { return }
        typealias Set = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method, to: Set.self)(preferences, selector, on)
    }
}

/// The delegate of a tab showing one of an extension's pages: WebKit's
/// question about recording the screen is answered here — yes only while
/// Shy's own call is under way in that page (ExtensionCapture.record),
/// no for anything else, however the extension got hold of getDisplayMedia.
/// Everything else goes on to the window's delegate, as for any tab. Web
/// tabs don't have one, and keep WebKit's own way: the Mac's picker.
@available(macOS 15.4, *)
final class ExtensionPageDelegate: NSObject, WKUIDelegate {
    weak var next: (WKNavigationDelegate & WKUIDelegate)?

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (next?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? { next }

    @objc(_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:)
    func displayCapture(_ web: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo, systemAudio: Bool,
                        decisionHandler: @escaping (Int) -> Void) {
        MainActor.assumeIsolated { decisionHandler(ExtensionCapture.shared.displayDecision(for: web)) }
    }
}
