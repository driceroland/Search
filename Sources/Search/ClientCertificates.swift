import AppKit
import Security
import WebKit

// A site that asks who you are with a certificate rather than a password: a
// company's sign-in, a bank's, a government's. The certificate and its key
// are in your keychain; the site names the authorities it accepts, and you
// pick one of your identities issued by them, as Safari has you do.
//
// Nothing of yours is sent unless you chose it here, or set it yourself for
// that site in Keychain Access (an identity preference). A coding agent's
// tab never gets one. A private tab asks for itself, whatever was chosen
// elsewhere, and forgets its choice when it closes.

/// One of your identities, as the picker names it.
struct ClientIdentity {
    let identity: SecIdentity
    let certificate: SecCertificate
    let name: String
    let issuer: String
    let expires: Date?

    var label: String {
        var text = name
        if !issuer.isEmpty { text += " — issued by \(issuer)" }
        if let expires { text += ", expires \(expires.formatted(date: .abbreviated, time: .omitted))" }
        return text
    }

    func same(as other: SecIdentity) -> Bool {
        var cert: SecCertificate?
        guard SecIdentityCopyCertificate(other, &cert) == errSecSuccess, let cert else { return false }
        return SecCertificateCopyData(cert) as Data == SecCertificateCopyData(certificate) as Data
    }
}

/// A certificate question held for one tab and one site. Every challenge
/// from that site while it is open waits on the same answer — a page opens
/// several connections at once, and each asks — and each is answered exactly
/// once, whatever happens: chosen, cancelled, or let go with its tab.
@MainActor
final class CertificateAsk {
    let tab: Tab.ID
    let site: String
    private var replies: [(URLSession.AuthChallengeDisposition, URLCredential?) -> Void]
    /// The sheet, once it is up, so a tab going away can take it down.
    weak var alert: NSAlert?

    init(tab: Tab.ID, site: String, reply: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        self.tab = tab
        self.site = site
        self.replies = [reply]
    }

    var open: Bool { !replies.isEmpty }

    func join(_ reply: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        replies.append(reply)
    }

    func answer(_ disposition: URLSession.AuthChallengeDisposition, _ credential: URLCredential? = nil) {
        let waiting = replies
        replies = []
        waiting.forEach { $0(disposition, credential) }
    }

    /// Let go without a choice: nothing is sent.
    func drop() {
        // Answered first, so the sheet's own ending finds nothing to answer.
        answer(.useCredential, nil)
        if let alert, let sheet = alert.window.sheetParent {
            sheet.endSheet(alert.window, returnCode: .cancel)
        }
    }

    deinit {
        let waiting = replies
        waiting.forEach { $0(.useCredential, nil) }
    }
}

enum ClientCertificates {
    /// The identity chosen for each site, this launch only, never for a
    /// private tab's. Keyed by the sign-ins (the website data store) as well
    /// as host and port: a private tab isn't answered for with what was
    /// chosen in a tab.
    @MainActor static var chosen: [String: SecIdentity] = [:]
    /// A private tab's choices: its own, for its own pages and what they
    /// load, never another tab's, and gone when it closes.
    @MainActor static var chosenInPrivate: [UUID: [String: SecIdentity]] = [:]

    /// A test run's picker: the identity at this index is chosen, or, nil,
    /// the picker is cancelled. Never a sheet on screen.
    @MainActor static var answerInTest: Int?
    /// What a test run's picker would have listed, each time it was asked.
    @MainActor static var askedInTest: [[String]] = []

    static func site(_ space: URLProtectionSpace) -> String {
        "\(space.host.lowercased()):\(space.port)"
    }

    @MainActor static func remembered(_ site: String, in webView: WKWebView) -> String {
        let store = webView.configuration.websiteDataStore.identifier?.uuidString ?? "default"
        return "\(store) \(site)"
    }

    /// Your identities whose certificate was issued by one of the
    /// authorities the site names, still valid today. A site that names none
    /// takes any of them, as in Safari.
    static func matching(_ issuers: [Data]?) -> [ClientIdentity] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnRef: true,
        ]
        if let issuers, !issuers.isEmpty { query[kSecMatchIssuers] = issuers }
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess,
              let identities = found as? [SecIdentity] else { return [] }
        var seen = Set<Data>()
        return identities.compactMap { identity -> ClientIdentity? in
            var cert: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert,
                  seen.insert(SecCertificateCopyData(cert) as Data).inserted else { return nil }
            let (issuer, expires) = describe(cert)
            if let expires, expires < Date() { return nil }
            let name = SecCertificateCopySubjectSummary(cert) as String? ?? "Certificate"
            return ClientIdentity(identity: identity, certificate: cert, name: name, issuer: issuer, expires: expires)
        }
    }

    /// The identity you set for this site yourself (Keychain Access ›
    /// New Identity Preference), which Safari uses without asking.
    static func preferred(for space: URLProtectionSpace, issuers: [Data]?) -> SecIdentity? {
        let port = space.port == 443 || space.port == 0 ? "" : ":\(space.port)"
        let valid = (issuers?.isEmpty == false ? issuers : nil) as CFArray?
        for name in ["https://\(space.host)\(port)/", space.host] {
            if let identity = SecIdentityCopyPreferred(name as CFString, nil, valid) { return identity }
        }
        return nil
    }

    /// The answer the site gets: the identity, with the authorities between
    /// it and its root, for a server that doesn't keep them itself.
    static func credential(_ identity: SecIdentity) -> URLCredential {
        var cert: SecCertificate?
        var between: [SecCertificate] = []
        if SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert {
            var trust: SecTrust?
            if SecTrustCreateWithCertificates(cert, SecPolicyCreateBasicX509(), &trust) == errSecSuccess, let trust {
                // Only what this Mac already has: never a fetch, on the main thread.
                SecTrustSetNetworkFetchAllowed(trust, false)
                _ = SecTrustEvaluateWithError(trust, nil)
                let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
                // Not the certificate itself (it goes as the identity), and
                // not a root, which the server has or doesn't.
                between = chain.dropFirst().filter { !selfSigned($0) }
            }
        }
        // Never kept by the network layer: what is remembered is kept here,
        // per store and site (a private tab: per tab), where an agent's never looks.
        return URLCredential(identity: identity, certificates: between.isEmpty ? nil : between, persistence: .none)
    }

    private static func selfSigned(_ cert: SecCertificate) -> Bool {
        let subject = SecCertificateCopyNormalizedSubjectSequence(cert) as Data?
        let issuer = SecCertificateCopyNormalizedIssuerSequence(cert) as Data?
        return subject != nil && subject == issuer
    }

    /// The issuer's common name and the date the certificate stops being valid.
    private static func describe(_ cert: SecCertificate) -> (String, Date?) {
        let keys = [kSecOIDX509V1IssuerName, kSecOIDX509V1ValidityNotAfter] as CFArray
        guard let values = SecCertificateCopyValues(cert, keys, nil) as? [CFString: Any] else { return ("", nil) }
        var issuer = ""
        if let entry = values[kSecOIDX509V1IssuerName] as? [CFString: Any],
           let parts = entry[kSecPropertyKeyValue] as? [[CFString: Any]] {
            let named = parts.first { ($0[kSecPropertyKeyLabel] as? String) == (kSecOIDCommonName as String) }
                ?? parts.first { ($0[kSecPropertyKeyLabel] as? String) == (kSecOIDOrganizationName as String) }
            issuer = named?[kSecPropertyKeyValue] as? String ?? ""
        }
        var expires: Date?
        if let entry = values[kSecOIDX509V1ValidityNotAfter] as? [CFString: Any],
           let seconds = (entry[kSecPropertyKeyValue] as? NSNumber)?.doubleValue {
            expires = Date(timeIntervalSinceReferenceDate: seconds)
        }
        return (issuer, expires)
    }
}

extension Browser {
    /// The tab a page belongs to, wherever it is shown: the row, put away, a
    /// peek, a little window.
    func certificateTab(for webView: WKWebView) -> Tab? {
        anyTab(for: webView) ?? (peekTab?.built === webView ? peekTab : nil)
            ?? LittleWindow.all.first { $0.tab.built === webView }?.tab
    }

    func clientCertificate(
        _ webView: WKWebView,
        _ challenge: URLAuthenticationChallenge,
        _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        // Nothing that isn't one of your tabs' pages answers as you.
        guard let tab = certificateTab(for: webView) else {
            return completionHandler(.useCredential, nil)
        }
        // A coding agent's tab never answers as you.
        if tab.agent {
            AgentControl.log.notice("a client certificate asked for in an agent's tab was refused")
            return completionHandler(.useCredential, nil)
        }
        let issuers = space.distinguishedNames
        let site = ClientCertificates.site(space)
        let key = ClientCertificates.remembered(site, in: webView)
        let remembers = !tab.shy

        // Yours, set for this site in Keychain Access: no question, as in Safari.
        if let preferred = ClientCertificates.preferred(for: space, issuers: issuers) {
            return completionHandler(.useCredential, ClientCertificates.credential(preferred))
        }
        let found = ClientCertificates.matching(issuers)
        guard !found.isEmpty else { return completionHandler(.performDefaultHandling, nil) }

        // Chosen for this site earlier this launch — a private tab: in that
        // tab — and still one it takes.
        let earlier = remembers ? ClientCertificates.chosen[key] : ClientCertificates.chosenInPrivate[tab.id]?[site]
        if let earlier, found.contains(where: { $0.same(as: earlier) }) {
            return completionHandler(.useCredential, ClientCertificates.credential(earlier))
        }
        // Cancelled on this page already: nothing more on it asks again,
        // from that site or any other.
        if certificateDeclined.contains(tab.id) {
            return completionHandler(.useCredential, nil)
        }
        // One question per tab at a time. The same site again waits for the
        // same answer; another site gets nothing rather than a second sheet.
        if let asking = certificateAsks.first(where: { $0.tab == tab.id && $0.open }) {
            return asking.site == site ? asking.join(completionHandler) : completionHandler(.useCredential, nil)
        }
        let question = CertificateAsk(tab: tab.id, site: site, reply: completionHandler)
        certificateAsks.append(question)
        let tabID = tab.id
        // nil: nothing sent; `refused` when it was you who said no.
        let finish: (ClientIdentity?, Bool) -> Void = { [weak self, weak question] picked, refused in
            let ask = question
            guard let self, let ask, ask.open else { return }
            self.certificateAsks.removeAll { $0 === ask }
            guard let picked else {
                if refused { self.certificateDeclined.insert(tabID) }
                return ask.answer(.useCredential, nil)
            }
            if remembers { ClientCertificates.chosen[key] = picked.identity }
            else { ClientCertificates.chosenInPrivate[tabID, default: [:]][site] = picked.identity }
            ask.answer(.useCredential, ClientCertificates.credential(picked.identity))
        }
        // Over its own tab only, as a page's questions are (see ask): over
        // the tab in front it would pass for that page's.
        ask(from: webView, show: { [weak self, weak question] in
            guard let self, let ask = question, ask.open else { return }
            self.showCertificatePicker(ask, host: space.host, found: found, over: webView, finish: finish)
        }, drop: { [weak self, weak question] in
            guard let ask = question else { return }
            self?.certificateAsks.removeAll { $0 === ask }
            ask.drop()
        })
    }

    private func showCertificatePicker(_ ask: CertificateAsk, host: String, found: [ClientIdentity],
                                       over webView: WKWebView, finish: @escaping (ClientIdentity?, Bool) -> Void) {
        if Store.testing {
            ClientCertificates.askedInTest.append(found.map(\.label))
            let index = ClientCertificates.answerInTest
            return finish(index.flatMap { found.indices.contains($0) ? found[$0] : nil }, true)
        }
        // Another sheet already up on the window: this one would wait behind
        // it, out of reach of its tab closing, and come up later over
        // whatever is there then. Nothing is sent; the next load asks again.
        if Dialogs.window(for: webView)?.attachedSheet != nil {
            return finish(nil, false)
        }
        let alert = NSAlert()
        alert.messageText = "\(host) asks for a certificate"
        alert.informativeText = "Choose the certificate to identify yourself to this site. It is sent only if you continue."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        let menu = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26), pullsDown: false)
        // Items made one by one, each tagged with its place: addItem(withTitle:)
        // drops a title already there, and two cards can hold certificates
        // named alike, so the picked row would name another certificate.
        for (index, identity) in found.enumerated() {
            let item = NSMenuItem(title: identity.label, action: nil, keyEquivalent: "")
            item.tag = index
            menu.menu?.addItem(item)
        }
        menu.selectItem(at: 0)
        alert.accessoryView = menu
        ask.alert = alert
        Dialogs.show(alert, over: webView) { answer in
            let index = menu.selectedItem?.tag ?? -1
            finish(answer == .alertFirstButtonReturn && found.indices.contains(index) ? found[index] : nil, true)
        }
    }

    /// A tab closed, put away or on another page: what it was asked is
    /// taken down and answered with nothing sent. What it cancelled stays
    /// cancelled until you go somewhere yourself (Tab.go, reload): a page
    /// sending itself on to another could otherwise ask again and again.
    /// A tab gone for good: what it cancelled, and a private tab's choices.
    func forgetCertificates(for tab: Tab.ID) {
        certificateDeclined.remove(tab)
        ClientCertificates.chosenInPrivate.removeValue(forKey: tab)
    }

    func dropCertificateAsks(for tab: Tab.ID) {
        let dropping = certificateAsks.filter { $0.tab == tab }
        guard !dropping.isEmpty else { return }
        certificateAsks.removeAll { $0.tab == tab }
        dropping.forEach { $0.drop() }
    }
}
