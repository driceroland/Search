import AppKit
import Security
import SecurityInterface
import SwiftUI

/// Chrome DevTools' Privacy and security panel: the third-party cookie
/// report (DeveloperThirdPartyCookiesView), an Overview of the page's
/// security and the origins it loaded from, grouped as Chrome groups them,
/// each with its connection and certificate. The model is
/// DeveloperSecurity.swift.
///
/// The main origin's certificate is read from WKWebView's serverTrust
/// (SecCertificateCopyValues); other origins show the certificate summary
/// WebKit's inspector sends with their responses (`Security.Certificate`).
struct DeveloperSecurityView: View {
    @ObservedObject var session: DeveloperToolsSession
    /// Network, its filter set to this text: "View requests in Network panel".
    let showInNetwork: (String) -> Void
    /// The chosen origin; nil for Overview.
    @State private var selection: String?
    /// The system's verdict on the page's certificate; nil while it's asked.
    @State private var trusted: Bool?

    private var page: URL? { session.address }
    private var isHTTPS: Bool { page?.scheme?.lowercased() == "https" }
    private var trust: SecTrust? { isHTTPS ? session.web?.serverTrust : nil }
    private var chain: [SecCertificate] {
        guard let trust else { return [] }
        return SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
    }

    var body: some View {
        let origins = DeveloperSecurity.origins(session.requests, page: page)
        GeometryReader { space in
            if space.size.width >= 460 {
                HSplitView {
                    sidebar(origins).frame(minWidth: 140, idealWidth: 190, maxWidth: 300)
                    detail(origins)
                }
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Picker("Security", selection: $selection) {
                            Text("Overview").tag(String?.none)
                            Text("Third-party cookies").tag(Optional(Self.thirdPartyCookies))
                            ForEach(origins) { origin in Text(origin.origin).tag(Optional(origin.origin)) }
                        }
                        .labelsHidden().fixedSize()
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, DeveloperToolsStyle.gutter).frame(height: DeveloperToolsStyle.toolbarHeight)
                    .background(DeveloperToolsStyle.chrome)
                    Divider()
                    detail(origins)
                }
            }
        }
        .task(id: page?.absoluteString ?? "") { await evaluateTrust() }
    }

    // MARK: Sidebar

    /// The sidebar's Privacy row; no origin is spelled this way.
    static let thirdPartyCookies = "privacy:third-party-cookies"

    private func sidebar(_ origins: [DeveloperSecurity.Origin]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                heading("Privacy")
                row("Third-party cookies", image: "hand.raised", tint: .secondary, id: Self.thirdPartyCookies)
                heading("Security")
                let summary = currentSummary(origins)
                row("Overview", image: summary.isSecure ? "lock.fill" : "exclamationmark.triangle.fill",
                    tint: summary.isSecure ? Palette.safe : Palette.unsafe, id: nil)
                ForEach(DeveloperSecurity.grouped(origins)) { section in
                    heading(section.group.rawValue)
                    ForEach(section.origins) { origin in
                        let look = icon(origin)
                        row(origin.origin, image: look.image, tint: look.tint, id: origin.origin)
                    }
                }
            }
        }
        .background(DeveloperToolsStyle.chrome.opacity(0.4))
    }

    private func icon(_ origin: DeveloperSecurity.Origin) -> (image: String, tint: Color) {
        switch origin.group {
        case .unknown: return ("questionmark.circle", .secondary)
        case .main, .secure, .nonSecure:
            return DeveloperSecurity.isSecureScheme(origin.scheme)
                ? ("lock.fill", Palette.safe) : ("exclamationmark.triangle.fill", Palette.unsafe)
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title).fontWeight(.semibold).lineLimit(1)
            .padding(.horizontal, DeveloperToolsStyle.gutter).frame(height: DeveloperToolsStyle.toolbarHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DeveloperToolsStyle.chrome)
            .overlay(alignment: .bottom) { Divider() }
    }

    private func row(_ text: String, image: String, tint: Color, id: String?) -> some View {
        Button { selection = id } label: {
            HStack(spacing: 6) {
                Image(systemName: image).foregroundStyle(tint).frame(width: 14)
                Text(text).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, DeveloperToolsStyle.gutter).frame(height: DeveloperToolsStyle.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selection == id ? DeveloperToolsStyle.selected : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == id ? .isSelected : [])
    }

    // MARK: Detail

    @ViewBuilder
    private func detail(_ origins: [DeveloperSecurity.Origin]) -> some View {
        if selection == Self.thirdPartyCookies {
            DeveloperThirdPartyCookiesView(session: session, tools: session.networkTools, showInNetwork: showInNetwork)
        } else if let selection, let origin = origins.first(where: { $0.origin == selection }) {
            originDetail(origin)
        } else {
            overview(origins)
        }
    }

    private func mixedContent() -> [DeveloperToolsSession.Request] {
        DeveloperSecurity.mixedContent(session.requests, page: page)
    }

    private func currentSummary(_ origins: [DeveloperSecurity.Origin]) -> DeveloperSecurity.Summary {
        let mixed = !mixedContent().isEmpty || (isHTTPS && session.web?.hasOnlySecureContent == false)
        return DeveloperSecurity.summary(page: page, trusted: trusted, mixed: mixed)
    }

    /// One of the explanation cards under Chrome's summary.
    private struct Explanation: Identifiable {
        let title: String
        let summary: String
        let description: String
        let secure: Bool
        var items: [String] = []
        var action: (label: String, perform: () -> Void)?
        var id: String { title }
    }

    private func explanations(_ origins: [DeveloperSecurity.Origin]) -> [Explanation] {
        guard isHTTPS else {
            return [Explanation(title: "Connection", summary: "not secure",
                                description: "This page is insecure (unencrypted HTTP).", secure: false)]
        }
        var cards: [Explanation] = []
        let leaf = chain.first.map { DeveloperSecurity.fields($0) }
        let viewCertificate: (label: String, perform: () -> Void)? = trust == nil
            ? nil : (label: "View certificate", perform: { showCertificate() })
        if trusted == false {
            cards.append(Explanation(title: "Certificate", summary: "there are issues with the site's certificate chain",
                                     description: "The connection to this site is using a server certificate this Mac doesn't trust.",
                                     secure: false, action: viewCertificate))
        } else {
            let issuer = leaf?.issuer.map { " issued by " + $0 } ?? ""
            cards.append(Explanation(title: "Certificate", summary: "valid and trusted",
                                     description: "The connection to this site is using a valid, trusted server certificate\(issuer).",
                                     secure: true, action: viewCertificate))
        }
        let security = origins.first { $0.group == .main }?.security
        let connection = DeveloperSecurity.connection(protocol: security?.networkProtocol, cipher: security?.cipher)
        if let version = connection.networkProtocol, ["TLS 1.0", "TLS 1.1", "SSL 3.0"].contains(version) {
            cards.append(Explanation(title: "Connection", summary: "obsolete connection settings",
                                     description: "The connection to this site uses \(version), an obsolete protocol.",
                                     secure: false))
        } else if connection.settings.isEmpty {
            cards.append(Explanation(title: "Connection", summary: "secure connection settings",
                                     description: "The connection to this site is encrypted and authenticated.", secure: true))
        } else {
            cards.append(Explanation(title: "Connection", summary: "secure connection settings",
                                     description: "The connection to this site is encrypted and authenticated using \(connection.settings).",
                                     secure: true))
        }
        let mixed = mixedContent()
        if !mixed.isEmpty || session.web?.hasOnlySecureContent == false {
            let count = mixed.count
            let label = count == 1 ? "View 1 request in Network panel" : "View \(count) requests in Network panel"
            let viewRequests: (label: String, perform: () -> Void)? = count == 0
                ? nil : (label: label, perform: { showInNetwork("scheme:http") })
            cards.append(Explanation(title: "Resources", summary: "mixed content",
                                     description: "This page includes HTTP resources.", secure: false,
                                     items: mixed.map(\.url),
                                     action: viewRequests))
        } else {
            cards.append(Explanation(title: "Resources", summary: "all served securely",
                                     description: "All resources on this page are served securely.", secure: true))
        }
        return cards
    }

    private func overview(_ origins: [DeveloperSecurity.Origin]) -> some View {
        let summary = currentSummary(origins)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: summary.isSecure ? "lock.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(summary.isSecure ? Palette.safe : Palette.unsafe)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Security overview").foregroundStyle(.secondary)
                        Text(summary.title).font(.system(size: 14, weight: .semibold))
                            .accessibilityIdentifier("security-summary")
                    }
                }
                if let url = page {
                    Text(url.absoluteString).font(DeveloperToolsStyle.code).textSelection(.enabled)
                        .foregroundStyle(.secondary).lineLimit(2)
                }
                Divider()
                ForEach(explanations(origins)) { card in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: card.secure ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(card.secure ? Palette.safe : Palette.unsafe)
                        VStack(alignment: .leading, spacing: 4) {
                            (Text(card.title).fontWeight(.semibold) + Text(" – " + card.summary))
                            Text(card.description).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            ForEach(Array(card.items.prefix(50).enumerated()), id: \.offset) { _, url in
                                Text(url).font(DeveloperToolsStyle.code).textSelection(.enabled).lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            if let action = card.action {
                                Button(action.label, action: action.perform).buttonStyle(.link)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        }
    }

    private func originDetail(_ origin: DeveloperSecurity.Origin) -> some View {
        let isMain = origin.group == .main
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(origin.group == .main ? "Main origin" : "Origin").foregroundStyle(.secondary)
                    Text(origin.origin).font(.system(size: 14, weight: .semibold)).textSelection(.enabled)
                }
                Button("View requests in Network panel") {
                    showInNetwork(DeveloperSecurity.networkFilter(for: origin))
                }
                .buttonStyle(.link)
                Divider()
                if origin.group == .unknown {
                    Text("No security details are available for this origin.").foregroundStyle(.secondary)
                } else if !DeveloperSecurity.isSecureScheme(origin.scheme) {
                    Text(DeveloperSecurity.isLoopback(origin.host)
                         ? "This origin is a non-HTTPS secure origin."
                         : "Your connection to this origin is not secure.")
                        .foregroundStyle(.secondary)
                } else {
                    let connection = DeveloperSecurity.connection(protocol: origin.security?.networkProtocol,
                                                                  cipher: origin.security?.cipher)
                    section("Connection")
                    pair("Protocol", connection.networkProtocol)
                    pair("Key exchange", connection.keyExchange)
                    pair("Cipher", connection.cipher)
                    section("Certificate")
                    if let fields = certificateFields(origin, isMain: isMain) {
                        pair("Subject", fields.subject)
                        pair("SAN", fields.alternativeNames.isEmpty ? nil : fields.alternativeNames.joined(separator: "\n"))
                        pair("Valid from", DeveloperSecurity.formatted(fields.validFrom))
                        pair("Valid until", DeveloperSecurity.formatted(fields.validUntil))
                        pair("Issuer", fields.issuer)
                    } else {
                        Text("No certificate details are available for this origin.").foregroundStyle(.secondary)
                    }
                    if isMain, trust != nil {
                        Button("Open full certificate details", action: showCertificate)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        }
    }

    private func certificateFields(_ origin: DeveloperSecurity.Origin, isMain: Bool) -> DeveloperSecurity.CertificateFields? {
        if isMain, let leaf = chain.first { return DeveloperSecurity.fields(leaf) }
        return origin.security?.certificate.map { DeveloperSecurity.fields($0) }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).padding(.top, 4)
    }

    private func pair(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
            Text(value ?? "—").font(DeveloperToolsStyle.code).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Certificate

    /// The system's certificate sheet for the page's trust, over DevTools' window.
    private func showCertificate() {
        guard let trust, let window = NSApp.keyWindow ?? NSApp.mainWindow ?? session.web?.window else { return }
        SFCertificatePanel.shared().beginSheet(
            for: window, modalDelegate: nil, didEnd: nil, contextInfo: nil, trust: trust, showGroup: true
        )
    }

    private func evaluateTrust() async {
        trusted = nil
        guard let trust else { return }
        // The asynchronous API leaves the main thread free during revocation checks.
        let ok = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let status = SecTrustEvaluateAsyncWithError(trust, .main) { _, result, _ in
                continuation.resume(returning: result)
            }
            if status != errSecSuccess { continuation.resume(returning: false) }
        }
        if !Task.isCancelled { trusted = ok }
    }
}
